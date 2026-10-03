#include <stdio.h>
#include <stdint.h>
#include <stdbool.h>
#include <signal.h>
#include <sys/mman.h>
#include <pthread.h>
#include <unistd.h>
#include <sched.h>
#include <os/base.h>
extern void os_set_custom_x18_abi_enabled(bool);
static inline void set18(uint64_t v){__asm__ volatile("mov x18, %0"::"r"(v));}
static inline uint64_t get18(void){uint64_t v;__asm__ volatile("mov %0, x18":"=r"(v));return v;}
static volatile char *page; static size_t ps;
static int mode; /* 0: just fix protection; 1: also write x18 in the context */
static void h(int s, siginfo_t *si, void *uc_){
  ucontext_t *uc=uc_;
  mprotect((void*)page,ps,PROT_READ|PROT_WRITE);
  if(mode) uc->uc_mcontext->__ss.__x[18]=0xABCD000000000000ULL;
}
static int faults(int m){
  mode=m; int bad=0;
  for(int i=0;i<200;i++){
    mprotect((void*)page,ps,PROT_NONE);
    uint64_t want=m?0xABCD000000000000ULL:0x5555000000000000ULL+i;
    set18(0x5555000000000000ULL+i);
    page[0]=1;                       /* SIGSEGV, handler fixes and returns */
    if(get18()!=want) bad++;
  }
  return bad;
}
static void *thr(void *a){
  if(a) os_set_custom_x18_abi_enabled(true);
  int lost=0; for(int i=0;i<200;i++){ set18(0x7777000000000000ULL+i); usleep(200); sched_yield(); if(get18()!=0x7777000000000000ULL+i) lost++; }
  return (void*)(intptr_t)lost;
}
int main(void){
  os_set_custom_x18_abi_enabled(true);
  ps=getpagesize(); page=mmap(0,ps,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);
  struct sigaction sa={0}; sa.sa_sigaction=h; sa.sa_flags=SA_SIGINFO; sigaction(SIGSEGV,&sa,0); sigaction(SIGBUS,&sa,0);
  printf("page fault + sigreturn: x18 wrong %d/200\n",faults(0));
  printf("sigreturn with x18 set in context: applied wrong %d/200\n",faults(1));
  pthread_t t; void *r;
  pthread_create(&t,0,thr,0); pthread_join(t,&r); printf("new thread without toggle: lost %ld/200\n",(long)r);
  pthread_create(&t,0,thr,(void*)1); pthread_join(t,&r); printf("new thread with toggle: lost %ld/200\n",(long)r);
  return 0;
}
