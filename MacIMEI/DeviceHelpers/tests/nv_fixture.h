/* Synthetic local fixtures only; not real device backups. */
static void fixture_imei(uint8_t *p, unsigned serial) {
    char digits[16];
    snprintf(digits,sizeof(digits),"00440000%06u",serial);
    int sum=0;
    for(int i=0;i<14;i++) { int d=digits[i]-'0';if(i%2) {d*=2;if(d>9)d-=9;}sum+=d; }
    digits[14]=(char)('0'+(10-sum%10)%10);digits[15]=0;
    p[0]=8;p[1]=(uint8_t)((digits[0]-'0')<<4|10);
    for(int i=0;i<7;i++) p[2+i]=(uint8_t)((digits[1+2*i]-'0')|((digits[2+2*i]-'0')<<4));
}
static void nv_fixture(void) {
    for(int i=0;i<2;i++) {
        for(int j=0;j<128;j++) original[i][j]=(uint8_t)(17*j+19*i);
        fixture_imei(original[i],(unsigned)(100+i));
        memcpy(target[i],original[i],128);
        fixture_imei(target[i],(unsigned)(200+i));
    }
    assert(plan_valid());
}
