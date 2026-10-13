/* Structure-only description of the EFS config format. Never prints payloads,
 * identifiers, or a hash of device-specific configuration. Unknown formats
 * remain unknown; this does not qualify the firmware for any write. */
static uint32_t support_config_crc(const uint8_t *p,size_t n) {
    uint32_t crc=0;
    for(size_t i=0;i<n;i++) {
        crc^=(uint32_t)((i>=12&&i<16)?0:p[i])<<24;
        for(unsigned j=0;j<8;j++) crc=(crc&0x80000000u)?(crc<<1)^0x04c11db7u:crc<<1;
    }
    return crc;
}
static void support_config_summary(const uint8_t *p,size_t n) {
    int magic=n>=20&&le32(p)==0x78563412u;
    printf("SUPPORT_CONFIG_FORMAT bytes=%zu magic_known=%d\n",n,magic);
    if(!magic) { puts("SUPPORT_CONFIG_STRUCTURE valid=0 reason=unknown_header");return; }
    uint32_t count=le32(p+4);
    int length_ok=le32(p+8)==n,trailer=le32(p+n-4)==0x21436587u;
    int crc=le32(p+12)==support_config_crc(p,n);
    printf("SUPPORT_CONFIG_HEADER records=%u declared_size=%u length_valid=%d trailer_known=%d crc_valid=%d\n",count,le32(p+8),length_ok,trailer,crc);
    if(!length_ok||!trailer||count>(n-20)/16) { puts("SUPPORT_CONFIG_STRUCTURE valid=0 reason=invalid_header");return; }
    uint8_t seen[65536/8]={0};
    size_t offset=16;
    unsigned flag_count=0;
    for(uint32_t index=0;index<count;index++) {
        if(offset>n-4||n-4-offset<16) {
            printf("SUPPORT_CONFIG_STRUCTURE valid=0 reason=truncated_record index=%u offset=%zu\n",index,offset);return;
        }
        uint32_t id=le32(p+offset),length=le32(p+offset+4);
        if(id>65535||length<16||length>n-4-offset||le32(p+offset+8)!=0x18080820u) {
            printf("SUPPORT_CONFIG_STRUCTURE valid=0 reason=invalid_record index=%u offset=%zu\n",index,offset);return;
        }
        if(seen[id/8]&(1u<<(id%8))) {
            printf("SUPPORT_CONFIG_STRUCTURE valid=0 reason=duplicate_id index=%u id=%u\n",index,id);return;
        }
        seen[id/8]|=(uint8_t)(1u<<(id%8));
        printf("SUPPORT_CONFIG_RECORD index=%u id=%u offset=%zu length=%u reserved_zero=%d\n",index,id,offset,length,le32(p+offset+12)==0);
        if(id==102) {
            flag_count++;
            int value=length==17&&p[offset+16]<=1?p[offset+16]:-1;
            printf("SUPPORT_CONFIG_FLAG102 offset=%zu length=%u value=%d b31_layout=%d\n",offset,length,value,index==5&&offset==483&&length==17&&value>=0&&le32(p+offset+12)==0);
        }
        offset+=length;
    }
    printf("SUPPORT_CONFIG_STRUCTURE valid=%d reason=%s consumed=%zu flag102_count=%u\n",offset==n-4&&crc,offset!=n-4?"trailing_data":!crc?"invalid_crc":"complete",offset,flag_count);
}
