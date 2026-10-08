/* Independent integer/rounding semantics; no reference code in the player. */
#include "lamp-test.h"
#include <limits.h>
#include <math.h>
typedef struct { int16_t a[8],b[8]; uint32_t c[4]; double d; uint64_t x,y; uint32_t borrow,count; } Input;
typedef struct { uint32_t sums[4]; int64_t nearest,truncated; int32_t n32,t32; uint64_t difference,loops,packed; unsigned char flags[6]; } Output;
LAMP_ABI void mac_translation_probe(const Input *,Output *);
static uint64_t state=0xc753280d;
static uint64_t next(void) {state^=state<<13;state^=state>>7;state^=state<<17;return state;}
static int64_t integer(double d,int bits,int nearest) {
    double rounded=nearest?nearbyint(d):trunc(d), bound=ldexp(1.,bits-1);
    if(!isfinite(rounded)||rounded < -bound||rounded >= bound)return bits==32?INT32_MIN:INT64_MIN;
    return (int64_t)rounded;
}
#define CHECK(x) do {if(!(x)){fprintf(stderr,"case %u line %d: %s\n",i,__LINE__,#x);return 1;}} while(0)
int main(void) {
    const double special[]={0.,-.0,.5,-.5,1.5,2.5,-1.5,-2.5,INFINITY,-INFINITY,NAN,
        2147483647.,2147483647.5,2147483648.,-2147483648.,-2147483648.5,
        0x1p63,-0x1p63,0x1.fffffffffffffp62,-0x1.0000000000001p63};
    for(unsigned i=0;i<40000;i++) {
        _Alignas(16) Input in; Output out={0};
        for(unsigned j=0;j<8;j++){in.a[j]=(int16_t)next();in.b[j]=(int16_t)next();}
        if(i%17==0)for(unsigned j=0;j<8;j++)in.a[j]=in.b[j]=INT16_MIN;
        for(unsigned j=0;j<4;j++)in.c[j]=(uint32_t)next();
        uint64_t raw=next();memcpy(&in.d,&raw,8);
        if(i<sizeof(special)/sizeof(*special))in.d=special[i];
        in.x=next();in.y=next();in.borrow=next()&1;in.count=1+(next()&7);
        if(i%19==0){in.x=0;in.y=UINT64_MAX;}
        mac_translation_probe(&in,&out);
        for(unsigned j=0;j<4;j++) {
            uint32_t want=(uint32_t)((int64_t)in.a[2*j]*in.b[2*j]+(int64_t)in.a[2*j+1]*in.b[2*j+1])+in.c[j];
            CHECK(out.sums[j]==want);
        }
        CHECK(out.nearest==integer(in.d,64,1));CHECK(out.truncated==integer(in.d,64,0));
        CHECK(out.n32==integer(in.d,32,1));CHECK(out.t32==integer(in.d,32,0));
        uint64_t difference=in.x-in.y-in.borrow;
        CHECK(out.difference==difference);CHECK(out.loops==in.count);CHECK(out.packed==1);
        CHECK(out.flags[0]==1);
        CHECK(out.flags[1]==(in.x<in.y || (in.borrow && in.x==in.y)));
        CHECK(out.flags[2]==(((in.x^in.y)&(in.x^difference))>>63));
        CHECK(out.flags[3]==(difference==0));CHECK(out.flags[4]==1);CHECK(out.flags[5]==1);
    }
    puts("{\"result\":\"passed\",\"cases\":40000,\"checks_per_case\":17}");return 0;
}
