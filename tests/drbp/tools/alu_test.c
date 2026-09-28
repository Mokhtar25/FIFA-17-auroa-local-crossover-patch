#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
typedef uint64_t DWORD64;
static DWORD64 xbp_alu( unsigned int alu, unsigned int width, DWORD64 a, DWORD64 b,
                        DWORD64 efl, DWORD64 *result )
{
    unsigned int bits = width * 8, p, cf = efl & 1;
    DWORD64 mask = bits == 64 ? ~(DWORD64)0 : ((DWORD64)1 << bits) - 1;
    DWORD64 sign = (DWORD64)1 << (bits - 1), res;

    a &= mask;
    b &= mask;
    efl &= ~(DWORD64)0x8d5;
    switch (alu)
    {
    case 0:   /* add */
    case 2:   /* adc */
    {
        unsigned __int128 sum = (unsigned __int128)a + b + (alu == 2 ? cf : 0);

        res = (DWORD64)sum & mask;
        if ((DWORD64)(sum >> bits) & 1) efl |= 0x001;       /* CF: carry out */
        if (~(a ^ b) & (a ^ res) & sign) efl |= 0x800;      /* OF */
        if ((a ^ b ^ res) & 0x10) efl |= 0x010;             /* AF */
        break;
    }
    case 3:   /* sbb */
    case 5:   /* sub */
    case 7:   /* cmp */
    {
        DWORD64 borrow = alu == 3 ? cf : 0;

        res = (a - b - borrow) & mask;
        if (a < b || (borrow && a == b)) efl |= 0x001;     /* CF: borrow */
        if ((a ^ b) & (a ^ res) & sign) efl |= 0x800;      /* OF */
        if ((a ^ b ^ res) & 0x10) efl |= 0x010;             /* AF */
        break;
    }
    case 1:  res = a | b; break;
    case 4:  res = a & b; break;
    default: res = a ^ b; break;
    }
    if (!res) efl |= 0x040;                                 /* ZF */
    if (res & sign) efl |= 0x080;                           /* SF */
    p = res & 0xff;
    p ^= p >> 4;
    p ^= p >> 2;
    p ^= p >> 1;
    if (!(p & 1)) efl |= 0x004;                             /* PF: even parity of the low byte */
    *result = res;
    return efl;
}
#define OP(name, suf, reg) \
static DWORD64 nat_##name##suf(DWORD64 a, DWORD64 b, DWORD64 efl, DWORD64 *r) { \
    DWORD64 f; __typeof__(a) x = a; \
    __asm__ volatile("pushq %3\n\tpopfq\n\t" #name #suf " %" reg "2, %" reg "0\n\tpushfq\n\tpopq %1" \
        : "+r"(x), "=r"(f) : "r"(b), "r"(efl) : "cc"); *r = x; return f; }
#define ALL(suf, reg) OP(add,suf,reg) OP(or,suf,reg) OP(adc,suf,reg) OP(sbb,suf,reg) OP(and,suf,reg) OP(sub,suf,reg) OP(xor,suf,reg) OP(cmp,suf,reg)
ALL(b,"b") ALL(l,"k") ALL(q,"q")
typedef DWORD64 (*natf)(DWORD64,DWORD64,DWORD64,DWORD64*);
natf tb[3][8] = {
 {nat_addb,nat_orb,nat_adcb,nat_sbbb,nat_andb,nat_subb,nat_xorb,nat_cmpb},
 {nat_addl,nat_orl,nat_adcl,nat_sbbl,nat_andl,nat_subl,nat_xorl,nat_cmpl},
 {nat_addq,nat_orq,nat_adcq,nat_sbbq,nat_andq,nat_subq,nat_xorq,nat_cmpq}};
static DWORD64 rnd(void){ DWORD64 v=((DWORD64)arc4random()<<32)|arc4random(); switch(arc4random()%6){case 0:return 0;case 1:return ~0ULL;case 2:return v&0xff;case 3:return 0x80ULL<<(8*(arc4random()%8));default:return v;} }
int main(void){
  int widths[3]={1,4,8}, bad=0; long n=0;
  for (int it=0; it<200000; it++) for (int w=0; w<3; w++) for (int op=0; op<8; op++) {
    DWORD64 a=rnd(), b=rnd(), efl=0x202|(arc4random()&1), rn, rm;
    DWORD64 mask = widths[w]==8?~0ULL:((1ULL<<(8*widths[w]))-1);
    DWORD64 fn = tb[w][op](a,b,efl,&rn);
    DWORD64 fm = xbp_alu(op, widths[w], a, b, efl, &rm);
    DWORD64 fmask = 0x8d5; if (op==1||op==4||op==6) fmask &= ~0x10;  /* AF undefined for logic ops */
    n++;
    if (((fn^fm)&fmask) || (op!=7 && ((rn^rm)&mask))) { if (bad++<10) printf("MISMATCH op%d w%d a=%llx b=%llx efl=%llx nat f=%llx r=%llx mine f=%llx r=%llx\n",op,widths[w],a,b,efl,fn,rn&mask,fm,rm); }
  }
  printf("%ld cases, %d mismatches\n", n, bad); return bad!=0;
}
