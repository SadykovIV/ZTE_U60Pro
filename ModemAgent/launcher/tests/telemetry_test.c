#include "../telemetry.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
static unsigned checks;
#define CHECK(x) do {checks++;if(!(x)){fprintf(stderr,"FAIL %s:%d: %s\n",__FILE__,__LINE__,#x);exit(1);}}while(0)
static struct telemetry_radio_fields fixture(void){
 /* Synthetic serving/CA values cover active and inactive carrier states.
    Band locks deliberately are not part of the parser contract. B7 is configured,
    but its state=1 means it must not be reported as an active carrier. */
 struct telemetry_radio_fields f={0};
 f.network_type="LTE-NSA";f.wan_active_band="LTE BAND 3";f.wan_active_channel="1301";f.lte_pci="107";f.lte_rsrp="-86";f.signalbar="5";
 f.lteca="107,3,0,1301,20;54,1,2,525,15;314,7,1,3300,10;160,8,2,3648,5;";
 f.ltecasig="-92.4,-12.8,14.0,-60.8,1,2;-103.1,-11.1,10.0,-83.0,0,1;-105.3,-17.8,8.0,-73.6,0,2;";
 f.nr5g_rsrp="0";f.nrca="";return f;
}
static void cpu_tests(void){
 struct telemetry_cpu_sample a,b,last={0};int percent=-1;
 CHECK(telemetry_cpu_parse("cpu  10 2 3 85 0 0 0 0 2 1\n",1000,&a));
 CHECK(a.total==100&&a.idle==85); /* guest fields never double counted */
 CHECK(!telemetry_cpu_percent(&last,&a,&percent));CHECK(percent==-1);
 CHECK(telemetry_cpu_parse("cpu 30 2 3 165 0 0 0 0\n",2000,&b));
 CHECK(telemetry_cpu_percent(&last,&b,&percent)&&percent==20);
 CHECK(telemetry_cpu_parse("cpu 130 2 3 165 0 0 0 0\n",3000,&a));
 CHECK(telemetry_cpu_percent(&last,&a,&percent)&&percent==100);
 CHECK(telemetry_cpu_parse("cpu 130 2 3 265 0 0 0 0\n",4000,&b));
 CHECK(telemetry_cpu_percent(&last,&b,&percent)&&percent==0);
 CHECK(!telemetry_cpu_percent(&last,&b,&percent)); /* unchanged counters */
 CHECK(telemetry_cpu_parse("cpu 1 1 1 1\n",5000,&a));CHECK(!telemetry_cpu_percent(&last,&a,&percent)); /* reboot/reset */
 CHECK(telemetry_cpu_parse("cpu 2 1 1 2\n",30000,&b));CHECK(!telemetry_cpu_percent(&last,&b,&percent)); /* resume after sleep */
 CHECK(telemetry_cpu_parse("cpu 3 1 1 3\n",30100,&a));CHECK(!telemetry_cpu_percent(&last,&a,&percent)); /* not enough sampling time */
 CHECK(!telemetry_cpu_parse("cpu0 1 2 3 4",40000,&a));CHECK(!telemetry_cpu_parse("cpu 1 2 3",40000,&a));
 CHECK(!telemetry_cpu_parse("cpu -1 2 3 4",40000,&a));CHECK(!telemetry_cpu_parse("cpu 1x 2 3 4",40000,&a));
 CHECK(!telemetry_cpu_parse("cpu 18446744073709551615 2 3 4",40000,&a));
 CHECK(!telemetry_cpu_parse("cpu 18446744073709551616 0 0 0",40000,&a));
 CHECK(!telemetry_cpu_parse("cpu 1 2 3 4 5 6 7 8 9 10 11",40000,&a));
 CHECK(!telemetry_cpu_percent(&last,&a,&percent)&&!last.valid);
}
static void radio_tests(void){
 struct modem_telemetry t={0};struct telemetry_radio_fields f=fixture();
 telemetry_update_radio(&t,&f,1000);
 CHECK((t.valid&(TELEMETRY_SIGNAL|TELEMETRY_RAT|TELEMETRY_CARRIERS))==(TELEMETRY_SIGNAL|TELEMETRY_RAT|TELEMETRY_CARRIERS));
 CHECK(!t.stale);CHECK(!strcmp(t.network_type,"LTE (NSA)"));CHECK(!strcmp(t.signal_metric,"RSRP")&&t.signal_dbm==-86);
 CHECK(t.carrier_count==3&&t.carriers_complete);CHECK(!strcmp(t.carrier_bands,"B3 + B1 + B8"));
 /* A missing status vector must not turn configured SCCs into active SCCs. */
 f.ltecasig=NULL;telemetry_update_radio(&t,&f,2000);
 CHECK(t.carrier_count==1&&!t.carriers_complete&&!strcmp(t.carrier_bands,"B3"));
 f=fixture();f.ltecasig="-90,-10,20,-50,1,garbage;";telemetry_update_radio(&t,&f,3000);
 CHECK(t.carrier_count==1&&!t.carriers_complete);
 /* Different channels in the same band are separate carriers. */
 f=fixture();f.network_type="LTE";f.lteca="107,3,0,1301,20;101,3,2,1400,20;101,3,2,1400,20;";
 f.ltecasig="-90,-10,20,-50,1,2;-90,-10,20,-50,1,2;";telemetry_update_radio(&t,&f,4000);
 CHECK(t.carrier_count==2&&!strcmp(t.carrier_bands,"B3 + B3"));
 /* 5G NSA uses both real serving carriers and excludes inactive NR SCCs. */
 f=fixture();f.nr5g_action_band="n78";f.nr5g_pci="52";f.nr5g_action_channel="640000";f.nr5g_rsrp="-91.2";
 f.nrca="1,52,2,78,640000,100,0,-91,-10,12,-56;1,53,2,78,650000,100,0,-92,-10,12,-56;0,54,1,1,428000,20,0,-92,-10,12,-56;";
 telemetry_update_radio(&t,&f,5000);CHECK(t.carrier_count==5&&t.carriers_complete);
 CHECK(!strcmp(t.network_type,"5G NSA")&&!strcmp(t.carrier_bands,"B3 + B1 + B8 + n78 + n78"));CHECK(t.signal_dbm==-91);
 f.network_type="NR5G-SA";telemetry_update_radio(&t,&f,6000);
 CHECK(t.carrier_count==2&&!strcmp(t.carrier_bands,"n78 + n78")&&!strcmp(t.network_type,"5G SA"));
 f.network_type="5G";telemetry_update_radio(&t,&f,6500);CHECK(!strcmp(t.network_type,"5G"));
 CHECK(t.carrier_count==2&&!t.carriers_complete); /* LTE anchor cannot be excluded by generic RAT */
 /* Phantom NR band/channel with zero RSRP is not an active 5G serving cell. */
 f=fixture();f.nr5g_action_band="n78";f.nr5g_pci="52";f.nr5g_action_channel="640000";
 telemetry_update_radio(&t,&f,7000);CHECK(t.carrier_count==3&&!strcmp(t.network_type,"LTE (NSA)"));
 memset(&t,0,sizeof t);memset(&f,0,sizeof f);f.network_type="LTE";f.signalbar="0";
 telemetry_update_radio(&t,&f,8000);CHECK(!(t.valid&TELEMETRY_CARRIERS));CHECK(t.valid&TELEMETRY_SIGNAL);CHECK(t.signal_bars==0&&!strcmp(t.signal_metric,"BARS"));
 f.signalbar="99";telemetry_update_radio(&t,&f,9000);CHECK(t.stale&TELEMETRY_SIGNAL);
 f.network_type="HSPA+";f.rscp="-96";telemetry_update_radio(&t,&f,10000);
 CHECK(!strcmp(t.network_type,"3G")&&!strcmp(t.signal_metric,"RSCP")&&t.signal_dbm==-96);
 f.network_type="EDGE";f.rssi="-71";telemetry_update_radio(&t,&f,11000);
 CHECK(!strcmp(t.network_type,"2G")&&!strcmp(t.signal_metric,"RSSI")&&t.signal_dbm==-71);
 f.network_type="NO_SERVICE";telemetry_update_radio(&t,&f,12000);
 CHECK((t.valid&TELEMETRY_CARRIERS)&&t.carrier_count==0&&t.carriers_complete);
 f.network_type="<b>garbage</b>";telemetry_update_radio(&t,&f,13000);
 CHECK(!strcmp(t.network_type,"No service")&&(t.stale&TELEMETRY_RAT));
}
static void stale_temperature_tests(void){
 struct modem_telemetry t={0};struct telemetry_radio_fields f=fixture();int value=999;
 CHECK(telemetry_temperature("53600\n",&value)&&value==536);CHECK(telemetry_temperature("0",&value)&&value==0);
 CHECK(telemetry_temperature("-20000",&value)&&value==-200);CHECK(!telemetry_temperature("-273000",&value));
 CHECK(!telemetry_temperature("-40960",&value));CHECK(!telemetry_temperature("150000",&value));
 CHECK(!telemetry_temperature("NaN",&value));CHECK(!telemetry_temperature("53C",&value));CHECK(!telemetry_temperature("53000.3",&value));
 telemetry_update_radio(&t,&f,1000);telemetry_set_number(&t,TELEMETRY_CPU,42,1000);telemetry_set_number(&t,TELEMETRY_CPU_TEMP,530,1000);
 telemetry_source_failed(&t,TELEMETRY_MODEM_TEMP);CHECK(!(t.valid&TELEMETRY_MODEM_TEMP)&&!(t.stale&TELEMETRY_MODEM_TEMP));
 telemetry_update_radio(&t,NULL,2000);CHECK(t.stale==(TELEMETRY_SIGNAL|TELEMETRY_RAT|TELEMETRY_CARRIERS));CHECK(t.carrier_count==3);
 telemetry_update_radio(&t,&f,3000);CHECK(!t.stale);CHECK(t.updated_ms[2]==3000);
 telemetry_expire(&t,13000);CHECK(!t.stale);telemetry_expire(&t,13001);CHECK(t.stale==(TELEMETRY_CPU|TELEMETRY_CPU_TEMP));
 telemetry_expire(&t,15001);CHECK((t.stale&t.valid)==t.valid);
 telemetry_set_number(&t,TELEMETRY_CPU,0,16000);CHECK(!(t.stale&TELEMETRY_CPU)&&t.cpu_percent==0);
 telemetry_expire(&t,500);CHECK((t.stale&t.valid)==t.valid); /* monotonic reset */
}
static void malformed_tests(void){
 struct modem_telemetry t={0};struct telemetry_radio_fields f=fixture();
 f.wan_active_band="B3B7";telemetry_update_radio(&t,&f,1000);CHECK(!(t.valid&TELEMETRY_CARRIERS));
 f=fixture();f.lte_pci="-1";telemetry_update_radio(&t,&f,2000);CHECK(!(t.valid&TELEMETRY_CARRIERS));
 f=fixture();f.wan_active_channel="1301junk";telemetry_update_radio(&t,&f,3000);CHECK(!(t.valid&TELEMETRY_CARRIERS));
 f=fixture();f.lte_rsrp="0";telemetry_update_radio(&t,&f,4000);CHECK(!(t.valid&TELEMETRY_CARRIERS));
 f=fixture();char oversized[4200];memset(oversized,'1',sizeof oversized-1);oversized[sizeof oversized-1]=0;f.lteca=oversized;
 telemetry_update_radio(&t,&f,5000);CHECK(t.carrier_count==1&&!t.carriers_complete);
 f=fixture();f.lteca="107,3,0,1301,20;;54,1,2,525,15;";
 telemetry_update_radio(&t,&f,6000);CHECK(!t.carriers_complete&&t.carrier_count==1);
 f=fixture();f.lteca="107,3,0,1301,20;garbage;54,1,2,525,15;";
 telemetry_update_radio(&t,&f,7000);CHECK(!t.carriers_complete&&t.carrier_count==1);
 f=fixture();f.lteca="107,3,0,1301,20;";
 telemetry_update_radio(&t,&f,8000);CHECK(!t.carriers_complete&&t.carrier_count==1);
}
static void system_tests(void){
 uint64_t used=999,total=999,seconds=999;
 CHECK(telemetry_memory_parse("MemTotal: 524288 kB\nMemFree: 20000 kB\nMemAvailable: 233472 kB\n",&used,&total));
 CHECK(used==284*1048576ULL&&total==512*1048576ULL);
 CHECK(telemetry_memory_parse("MemAvailable: 0 kB\nMemTotal: 1024 kB\n",&used,&total)&&used==total&&total==1048576);
 CHECK(telemetry_memory_parse("MemAvailable: 1024 kB\nMemTotal: 1024 kB\n",&used,&total)&&used==0);
 CHECK(!telemetry_memory_parse("MemTotal: 1024 kB\nMemFree: 512 kB\n",&used,&total));
 CHECK(!telemetry_memory_parse("MemTotal: 0 kB\nMemAvailable: 0 kB\n",&used,&total));
 CHECK(!telemetry_memory_parse("MemTotal: 1024 kB\nMemAvailable: 1025 kB\n",&used,&total));
 CHECK(!telemetry_memory_parse("MemTotal: 1024 kB\nMemTotal: 1024 kB\nMemAvailable: 0 kB\n",&used,&total));
 CHECK(!telemetry_memory_parse("MemTotal: -1024 kB\nMemAvailable: 0 kB\n",&used,&total));
 CHECK(!telemetry_memory_parse("MemTotal: 1024 MB\nMemAvailable: 0 kB\n",&used,&total));
 CHECK(!telemetry_memory_parse("MemTotal: 1024 kB extra\nMemAvailable: 0 kB\n",&used,&total));
 CHECK(!telemetry_memory_parse("MemTotal: 18446744073709551615 kB\nMemAvailable: 0 kB\n",&used,&total));
 CHECK(!telemetry_memory_parse("MemTotal: 18446744073709551616 kB\nMemAvailable: 0 kB\n",&used,&total));
 CHECK(telemetry_uptime_parse("183845.95 900000.42\n",&seconds)&&seconds==183845);
 CHECK(telemetry_uptime_parse("0.00 0.00",&seconds)&&seconds==0);
 CHECK(!telemetry_uptime_parse("-1.00 0.00",&seconds));CHECK(!telemetry_uptime_parse("nan 0.0",&seconds));
 CHECK(!telemetry_uptime_parse("1.00 nan",&seconds));CHECK(!telemetry_uptime_parse("1.00",&seconds));
 CHECK(!telemetry_uptime_parse("1.00 2.00 trailing",&seconds));CHECK(!telemetry_uptime_parse("1000000000001 0",&seconds));
 struct modem_telemetry t={0};
 CHECK(telemetry_set_capacity(&t,TELEMETRY_MEMORY,0,1024,1000));CHECK(t.memory_used==0&&t.memory_total==1024&&t.valid==TELEMETRY_MEMORY);
 CHECK(telemetry_set_capacity(&t,TELEMETRY_STORAGE,1024,2048,1000));telemetry_set_uptime(&t,0,1000);
 CHECK(t.valid==(TELEMETRY_MEMORY|TELEMETRY_STORAGE|TELEMETRY_UPTIME)&&!t.stale);
 CHECK(!telemetry_set_capacity(&t,TELEMETRY_MEMORY,2048,1024,2000));CHECK(t.stale==TELEMETRY_MEMORY&&t.memory_used==0);
 CHECK(!telemetry_set_capacity(&t,TELEMETRY_STORAGE,0,0,2000));CHECK((t.stale&TELEMETRY_STORAGE)&&t.storage_total==2048);
 CHECK(!telemetry_set_capacity(&t,TELEMETRY_SIGNAL,0,1024,2000));
 telemetry_set_uptime(&t,12,2000);telemetry_expire(&t,14000);CHECK(!(t.stale&TELEMETRY_UPTIME));
 telemetry_expire(&t,14001);CHECK(t.stale==t.valid);
}
static void quality_tests(void){
 struct modem_telemetry t={0};struct telemetry_radio_fields f=fixture();
 /* Existing B31 captures show -16 dB and -1.0 dB: values are direct dB. */
 f.lte_rsrq="-16";f.lte_snr="-1.0";f.nr5g_rsrq="0";f.nr5g_snr="0.0";
 telemetry_update_radio(&t,&f,1000);
 CHECK((t.valid&(TELEMETRY_RSRQ|TELEMETRY_SINR))==(TELEMETRY_RSRQ|TELEMETRY_SINR));
 CHECK(t.rsrq_tenths==-160&&t.sinr_tenths==-10&&!t.rsrq_is_nr&&!t.sinr_is_nr&&!t.stale);
 /* A proven NR serving cell wins over the LTE anchor, and retains its source. */
 f.nr5g_action_band="n78";f.nr5g_pci="52";f.nr5g_action_channel="640000";f.nr5g_rsrp="-91.2";
 f.nr5g_rsrq="-11.5";f.nr5g_snr="15.6";telemetry_update_radio(&t,&f,2000);
 CHECK(t.rsrq_tenths==-115&&t.sinr_tenths==156&&t.rsrq_is_nr&&t.sinr_is_nr);
 CHECK(t.updated_ms[10]==2000&&t.updated_ms[11]==2000&&!t.stale);
 f.nr5g_rsrq="0";f.nr5g_snr="0";telemetry_update_radio(&t,&f,3000);
 CHECK(t.rsrq_tenths==0&&t.sinr_tenths==0&&!t.stale); /* Valid zero on an active cell. */
 f.nr5g_rsrq="";f.nr5g_snr=NULL;telemetry_update_radio(&t,&f,4000);
 CHECK((t.stale&(TELEMETRY_RSRQ|TELEMETRY_SINR))==(TELEMETRY_RSRQ|TELEMETRY_SINR));
 CHECK(t.rsrq_tenths==0&&t.sinr_tenths==0&&t.rsrq_is_nr&&t.sinr_is_nr); /* No mix with live LTE. */
 f.nr5g_rsrp="0";telemetry_update_radio(&t,&f,5000);
 CHECK(t.rsrq_tenths==-160&&t.sinr_tenths==-10&&!t.rsrq_is_nr&&!t.sinr_is_nr&&!t.stale);
 const char *invalid[]={"nan","inf","-inf","-50.1","50.1","999","-999","-1 dB","--1","1,5"};
 for(unsigned i=0;i<sizeof invalid/sizeof invalid[0];i++){
  memset(&t,0,sizeof t);f.lte_rsrq=invalid[i];f.lte_snr=invalid[i];telemetry_update_radio(&t,&f,6000);
  CHECK(!(t.valid&(TELEMETRY_RSRQ|TELEMETRY_SINR)));
 }
 memset(&t,0,sizeof t);f.lte_rsrq="-50";f.lte_snr="-30";telemetry_update_radio(&t,&f,7000);
 CHECK(t.rsrq_tenths==-500&&t.sinr_tenths==-300);f.lte_rsrq="20";f.lte_snr="50";telemetry_update_radio(&t,&f,8000);
 CHECK(t.rsrq_tenths==200&&t.sinr_tenths==500);
 f.lte_rsrq="20.1";f.lte_snr="-30.1";telemetry_update_radio(&t,&f,9000);
 CHECK((t.stale&(TELEMETRY_RSRQ|TELEMETRY_SINR))==(TELEMETRY_RSRQ|TELEMETRY_SINR));
 for(unsigned i=0;i<3;i++){
  memset(&t,0,sizeof t);f=fixture();f.network_type=i==0?"LTE":i==1?"HSPA+":"NO_SERVICE";
  f.lte_rsrp="0";f.lte_rsrq="0";f.lte_snr="0";telemetry_update_radio(&t,&f,10000);
  CHECK(!(t.valid&(TELEMETRY_RSRQ|TELEMETRY_SINR))); /* Placeholder zeros and stale LTE on 3G are unavailable. */
 }
 memset(&t,0,sizeof t);f=fixture();f.lte_rsrq="-12.34";f.lte_snr="0.16";telemetry_update_radio(&t,&f,11000);
 CHECK(t.rsrq_tenths==-123&&t.sinr_tenths==2);
 telemetry_expire(&t,23000);CHECK(!t.stale);telemetry_expire(&t,23001);CHECK((t.stale&t.valid)==t.valid);
 telemetry_update_radio(&t,&f,24000);CHECK(!t.stale);telemetry_update_radio(&t,NULL,25000);
 CHECK((t.stale&(TELEMETRY_RSRQ|TELEMETRY_SINR))==(TELEMETRY_RSRQ|TELEMETRY_SINR));
}
static void battery_tests(void){
 struct modem_telemetry t={0};
 CHECK(telemetry_update_battery(&t,"83","Charging",1000));CHECK(t.battery_percent==83&&t.battery_status==BATTERY_CHARGING&&t.valid==TELEMETRY_BATTERY);
 CHECK(telemetry_update_battery(&t,"0","Discharging",2000));CHECK(t.battery_percent==0&&t.battery_status==BATTERY_DISCHARGING);
 CHECK(telemetry_update_battery(&t,"100","Full",3000));CHECK(t.battery_percent==100&&t.battery_status==BATTERY_FULL);
 CHECK(telemetry_update_battery(&t,"75","Not charging",4000));CHECK(t.battery_status==BATTERY_NOT_CHARGING);
 CHECK(telemetry_update_battery(&t,"75","Unknown",5000));CHECK(t.battery_status==BATTERY_UNKNOWN&&!t.stale&&t.updated_ms[9]==5000);
 const char *invalid[]={NULL,"","-1","101","0.5","NaN","80%","80\n90"};
 for(unsigned i=0;i<sizeof invalid/sizeof invalid[0];i++)CHECK(!telemetry_update_battery(&t,invalid[i],"Charging",6000));
 CHECK(t.battery_percent==75&&t.stale==TELEMETRY_BATTERY);
 CHECK(!telemetry_update_battery(&t,"12",NULL,6000));CHECK(!telemetry_update_battery(&t,"12","garbage",6000));
 CHECK(!telemetry_update_battery(&t,"12","charging",6000));CHECK(!telemetry_update_battery(&t,"12","Charging\nDischarging",6000));
 CHECK(telemetry_update_battery(&t,"12","Charging",7000)&&!t.stale);telemetry_expire(&t,19000);CHECK(!t.stale);
 telemetry_expire(&t,19001);CHECK(t.stale==TELEMETRY_BATTERY);
 memset(&t,0,sizeof t);CHECK(!telemetry_update_battery(&t,NULL,NULL,20000)&&!t.valid&&!t.stale);
}
int main(void){cpu_tests();radio_tests();stale_temperature_tests();malformed_tests();system_tests();quality_tests();battery_tests();printf("telemetry: %u checks passed\n",checks);return 0;}
