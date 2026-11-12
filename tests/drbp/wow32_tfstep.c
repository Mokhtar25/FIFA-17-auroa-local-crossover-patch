/* wow32_tfstep: how Esp moves when a 32-bit guest single-steps (EFLAGS.TF)
 * through stack-touching instructions.  One line per instruction group: the
 * Eip reached after each step and the Esp change of that step.
 *
 * Measured on this build with no breakpoint emulation involved (the exe has
 * no DrTrap=3 entry): every group steps correctly except "call rel32" (E8),
 * which pushes an 8-byte return address under Rosetta, so its step reads
 * Esp -8 where Windows' is -4, and the callee's ret leaves the caller 4
 * bytes off.  call_reg and call_mem (FF /2) are -4.  The execute-breakpoint
 * emulation single-steps every instruction it runs from a page it stripped,
 * and undoes this for the instruction it steps (xbp_note_call/xbp_fix_call
 * in signal_x86_64.c); a guest that sets TF itself and steps over an E8 on
 * its own still sees -8.
 *
 * Build: i686-w64-mingw32-gcc -O1 -Wall -o wow32_tfstep.exe wow32_tfstep.c
 */
#define __USE_MINGW_ANSI_STDIO 1
#include <windows.h>
#include <stdio.h>
#include <string.h>
unsigned long savedsp, dummy[32], fptr, far_[2];
static DWORD log_ip[64], log_sp[64]; static int n, maxn;
void run_call_rel(void);
__asm__(".text\n.globl _run_call_rel\n_run_call_rel:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "call 1f\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_call_reg(void);
__asm__(".text\n.globl _run_call_reg\n_run_call_reg:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "movl $1f,%eax\n"
 " call *%eax\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_call_mem(void);
__asm__(".text\n.globl _run_call_mem\n_run_call_mem:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "call *(%ebx)\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_push_imm(void);
__asm__(".text\n.globl _run_push_imm\n_run_push_imm:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "pushl $5\n"
 " addl $4,%esp\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_push_reg(void);
__asm__(".text\n.globl _run_push_reg\n_run_push_reg:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "pushl %eax\n"
 " popl %eax\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_push_mem(void);
__asm__(".text\n.globl _run_push_mem\n_run_push_mem:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "pushl (%ebx)\n"
 " popl (%esi)\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_pushf(void);
__asm__(".text\n.globl _run_pushf\n_run_pushf:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "pushfl\n"
 " popfl\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_pusha(void);
__asm__(".text\n.globl _run_pusha\n_run_pusha:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "pushal\n"
 " popal\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_ret_imm(void);
__asm__(".text\n.globl _run_ret_imm\n_run_ret_imm:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "pushl $7\n"
 " call 3f\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_enter(void);
__asm__(".text\n.globl _run_enter\n_run_enter:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "enter $8,$0\n"
 " leave\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_movs(void);
__asm__(".text\n.globl _run_movs\n_run_movs:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "movsl\n"
 " rep movsb\n"
 " lodsl\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_cpuid(void);
__asm__(".text\n.globl _run_cpuid\n_run_cpuid:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "cpuid\n"
 " xchg %eax,%edx\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_jmpcc(void);
__asm__(".text\n.globl _run_jmpcc\n_run_jmpcc:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "jmp 4f\n"
 " 4: jnz 4f\n"
 " 4: loop 4f\n"
 " 4: nop\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");
void run_call_far(void);
__asm__(".text\n.globl _run_call_far\n_run_call_far:\n"
 "pushl %ebx\n pushl %esi\n pushl %edi\n pushl %ebp\n movl %esp,_savedsp\n"
 "movl $_fptr,%ebx\n movl $1f,(%ebx)\n movl $_dummy,%esi\n movl $_dummy+64,%edi\n movl $2,%ecx\n xorl %eax,%eax\n"
 "pushfl\n orl $0x100,(%esp)\n popfl\n nop\n"
 "pushl $0x107\n"
 " pushl $1f\n"
 " lcall *(%esp)\n"
 "jmp 5f\n 1: ret\n 3: ret $4\n 5: nop\n"
 "pushfl\n andl $0xfffffeff,(%esp)\n popfl\n movl _savedsp,%esp\n popl %ebp\n popl %edi\n popl %esi\n popl %ebx\n ret\n");

static LONG CALLBACK veh(EXCEPTION_POINTERS *e);
static LONG CALLBACK veh(EXCEPTION_POINTERS *e)
{
    CONTEXT *c = e->ContextRecord;
    if (e->ExceptionRecord->ExceptionCode != EXCEPTION_SINGLE_STEP) return EXCEPTION_CONTINUE_SEARCH;
    if (n < 64) { log_ip[n] = c->Eip; log_sp[n] = c->Esp; n++; }
    if (n < maxn && c->Eip >= (DWORD)(ULONG_PTR)run_call_rel && c->Eip < (DWORD)(ULONG_PTR)veh) c->EFlags |= 0x100;
    return EXCEPTION_CONTINUE_EXECUTION;
}
static struct { const char *name; void (*fn)(void); } tab[] = {
  {"call_rel", run_call_rel},
  {"call_reg", run_call_reg},
  {"call_mem", run_call_mem},
  {"push_imm", run_push_imm},
  {"push_reg", run_push_reg},
  {"push_mem", run_push_mem},
  {"pushf", run_pushf},
  {"pusha", run_pusha},
  {"ret_imm", run_ret_imm},
  {"enter", run_enter},
  {"movs", run_movs},
  {"cpuid", run_cpuid},
  {"jmpcc", run_jmpcc},
  {"call_far", run_call_far},
};
int main(void)
{
    unsigned i, j;
    AddVectoredExceptionHandler(1, veh);
    for (i = 0; i < sizeof tab / sizeof tab[0]; i++) {
        n = 0; maxn = 40;
        tab[i].fn();
        printf("%s:", tab[i].name);
        for (j = 1; j < (unsigned)n; j++) printf(" %08lx/%+ld", (unsigned long)log_ip[j], (long)log_sp[j]-(long)log_sp[j-1]);
        printf("\n");
    }
    return 0;
}
