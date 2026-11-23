/*
 * DFX warm-up milestone 2: load a partial bitstream into the reconfigurable partition through AXI HWICAP.
 * Partial bitstreams are placed in DDR2 by the host with xsdb (see scripts/dfx/load_and_test.tcl):
 *   RM A image at 0x87000000, RM B image at 0x87100000, each = [word count (LE u32)][big-endian config words].
 * Registers (xhwicap_l.h): WF 0x100, SZ 0x108, CR 0x10C (bit0 write, bit2 FIFO clear), SR 0x110 (bit0 done),
 * WFV 0x114 (write FIFO vacancy in words).
 *
 * UART commands: a = load RM A, b = load RM B, 0 1 2 3 = write test values, p = print din/dout/status.
 */
#include <stdint.h>
#include "xil_printf.h"
#include "sleep.h"

#ifndef HWICAP_BASE
#define HWICAP_BASE 0x40200000u
#endif
#define HW(off)   (*(volatile uint32_t *)(HWICAP_BASE + (off)))
#define HW_WF 0x100
#define HW_SZ 0x108
#define HW_CR 0x10C
#define HW_SR 0x110
#define HW_WFV 0x114
#define CR_WRITE 0x1u
#define CR_FIFO_CLR 0x4u
#define CR_SW_RESET 0x8u
#define SR_DONE 0x1u

#define RP_IN   (*(volatile uint32_t *)0x40010000u)
#define RP_OUT  (*(volatile uint32_t *)0x40010008u)
#define UART_RX   (*(volatile uint32_t *)0x40600000u)
#define UART_STAT (*(volatile uint32_t *)0x40600008u)

#define RM_A_ADDR 0x87000000u
#define RM_B_ADDR 0x87100000u

static inline uint32_t bswap32(uint32_t v)
{
    return (v >> 24) | ((v >> 8) & 0xFF00u) | ((v << 8) & 0xFF0000u) | (v << 24);
}

static int load_partial(uint32_t addr)
{
    const volatile uint32_t *img = (const volatile uint32_t *)addr;
    uint32_t nwords = img[0];
    if (nwords == 0 || nwords > 0x40000u) { xil_printf("bad word count %u at 0x%08x\r\n", (unsigned)nwords, (unsigned)addr); return -1; }
    const volatile uint32_t *w = img + 1;

    /* Reset and FIFO-clear are level bits: set, hold >= 3 clocks, then clear (as in xhwicap.c). */
    HW(HW_CR) = CR_SW_RESET;  usleep(10);  HW(HW_CR) = 0;
    HW(HW_CR) = CR_FIFO_CLR;  usleep(10);  HW(HW_CR) = 0;

    uint32_t done_words = 0;
    while (done_words < nwords) {
        uint32_t vac = HW(HW_WFV);
        if (vac > nwords - done_words) vac = nwords - done_words;
        for (uint32_t i = 0; i < vac; i++) HW(HW_WF) = bswap32(w[done_words + i]);
        HW(HW_CR) = CR_WRITE;
        while (HW(HW_CR) & CR_WRITE) { }         /* hardware clears the bit when the FIFO has drained */
        done_words += vac;
    }
    while (!(HW(HW_SR) & SR_DONE)) { }
    xil_printf("loaded %u words, SR=0x%08x\r\n", (unsigned)nwords, (unsigned)HW(HW_SR));
    return 0;
}

static void show(uint32_t v)
{
    RP_IN = v;
    usleep(1000);
    xil_printf("wrote 0x%08x  partition output 0x%08x\r\n", (unsigned)v, (unsigned)RP_OUT);
}

int main(void)
{
    xil_printf("\r\n=== DFX warm-up: partial reconfiguration via HWICAP ===\r\n");
    show(0x12345678u);
    xil_printf("Commands: a = load RM A, b = load RM B, 0 1 2 3 = values, p = print\r\n");
    for (;;) {
        if (!(UART_STAT & 1u)) continue;
        switch ((char)(UART_RX & 0xFF)) {
        case 'a': load_partial(RM_A_ADDR); show(RP_IN); break;
        case 'b': load_partial(RM_B_ADDR); show(RP_IN); break;
        case '0': show(0x12345678u); break;
        case '1': show(0xDEADBEEFu); break;
        case '2': show(0x01234567u); break;
        case '3': show(0x89ABCDEFu); break;
        case 'p': xil_printf("din 0x%08x dout 0x%08x SR=0x%08x\r\n", (unsigned)RP_IN, (unsigned)RP_OUT, (unsigned)HW(HW_SR)); break;
        default: break;
        }
    }
}
