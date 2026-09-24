/* Exact public schema with generated, non-private record payloads. */
static void config_fixture(void) {
    memset(config_original,0,sizeof(config_original));
    put32(config_original,0x78563412u);put32(config_original+4,249);
    put32(config_original+8,CONFIG_SIZE);
    size_t offset=16;
    for(unsigned i=0;i<249;i++) {
        unsigned length=i<4?93:i==4?95:i==5?17:i==248?291:59;
        uint8_t *p=config_original+offset;
        put32(p,i==5?102:1000+i);put32(p+4,length);put32(p+8,0x18080820u);
        for(unsigned j=16;j<length;j++) p[j]=(uint8_t)(i+7*j);
        offset+=length;
    }
    assert(offset==CONFIG_SIZE-4);
    config_original[499]=0;
    put32(config_original+CONFIG_SIZE-4,0x21436587u);
    put32(config_original+12,config_crc(config_original));
    memcpy(config_candidate,config_original,CONFIG_SIZE);config_candidate[499]=1;
    put32(config_candidate+12,config_crc(config_candidate));
    assert(plan_valid());
}
