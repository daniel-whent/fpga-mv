/*
 * DFX warm-up milestone 2: load a partial bitstream into the reconfigurable partition through AXI HWICAP.
 * Partial bitstreams are placed in DDR2 by the host with xsdb (see scripts/dfx/load_and_test.tcl):
 *   RM A image at 0x87000000, RM B image at 0x87100000, each = [word count (LE u32)][big-endian config words].
 * Registers (xhwicap_l.h): WF 0x100, SZ 0x108, CR 0x10C (bit0 write, bit2 FIFO clear), SR 0x110 (bit0 done),
 * WFV 0x114 (write FIFO vacancy in words).
 *

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

/* Addresses from the block design address map (printed by scripts/dfx/create_bd_rp_axi.tcl). */
#ifndef DEC_BASE
#define DEC_BASE 0x44A00000u      /* dfx_decoupler control register block (s_axi_reg) */
#endif
#ifndef ASM_BASE
#define ASM_BASE 0x44A10000u      /* dfx_axi_shutdown_manager control register */
#endif
#ifndef RP_BASE
#define RP_BASE  0x44A20000u      /* reconfigurable partition AXI4-Lite slave (through the decoupler) */
#endif
#define DEC_CTRL  (*(volatile uint32_t *)(DEC_BASE + 0x0))
/* shutdown manager (xdfxasm_hw.h): write 1 = shutdown, 0 = pass-through. Read: bit0 requested,
 * bit1 both channels in shutdown, bit2 write channel, bit3 read channel. */
#define ASM_CTRL  (*(volatile uint32_t *)(ASM_BASE + 0x0))
#ifndef RST_BASE
#define RST_BASE 0x40010000u      /* axi_gpio_rst: bit0 = partition reset released (0 = in reset) */
#endif
#define RP_RST    (*(volatile uint32_t *)(RST_BASE + 0x0))
#define RP_VALUE  (*(volatile uint32_t *)(RP_BASE + 0x0))
#define RP_ID     (*(volatile uint32_t *)(RP_BASE + 0x4))
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

static uint32_t last_value = 0x12345678u;

static void show(uint32_t v)
{
    last_value = v;
    RP_VALUE = v;
    xil_printf("wrote 0x%08x  module id 0x%08x  value readback 0x%08x\r\n",
               (unsigned)v, (unsigned)RP_ID, (unsigned)RP_VALUE);
}

static int asm_shutdown(void)
{
    ASM_CTRL = 1;
    for (int i = 0; i < 100000; i++) {
        if (ASM_CTRL & 0x2u) return 0;           /* both channels shut down */
    }
    xil_printf("shutdown manager did not reach shutdown, state 0x%x\r\n", (unsigned)ASM_CTRL);
    return -1;
}

/* Swap modules: shut down the bus, decouple, push the partial bitstream, re-couple, resume, restore value. */
static void swap_to(uint32_t addr)
{
    if (asm_shutdown() != 0) { ASM_CTRL = 0; return; }
    DEC_CTRL = 1;
    int rc = load_partial(addr);
    /* A partial bitstream does not initialize the new module's flip-flops: pulse its local reset while it is
     * still decoupled, then re-couple and resume traffic. */
    RP_RST = 0;
    usleep(10);
    RP_RST = 1;
    usleep(10);
    DEC_CTRL = 0;
    ASM_CTRL = 0;
    if (rc == 0) show(last_value);
}

int main(void)
{
    xil_printf("\r\n=== DFX: AXI4-Lite partition behind a DFX decoupler ===\r\n");
    DEC_CTRL = 0;
    xil_printf("decoupler control 0x%08x\r\n", (unsigned)DEC_CTRL);
    show(0x12345678u);
    xil_printf("Commands: a/b = swap to RM A/B (decoupled), 0 1 2 3 = values, i/r = read id, s = shutdown mgr on, p = pass-through, d/e = decouple on/off\r\n");
    for (;;) {
        if (!(UART_STAT & 1u)) continue;
        switch ((char)(UART_RX & 0xFF)) {
        case 'a': swap_to(RM_A_ADDR); break;
        case 'b': swap_to(RM_B_ADDR); break;
        case '0': show(0x12345678u); break;
        case '1': show(0xDEADBEEFu); break;
        case '2': show(0x01234567u); break;
        case '3': show(0x89ABCDEFu); break;
        case 'i': xil_printf("module id 0x%08x\r\n", (unsigned)RP_ID); break;
        case 's': { int rc = asm_shutdown(); xil_printf("shutdown: %d, state 0x%x\r\n", rc, (unsigned)ASM_CTRL); break; }
        case 'p': ASM_CTRL = 0; xil_printf("pass-through, state 0x%x\r\n", (unsigned)ASM_CTRL); break;
        case 'r': xil_printf("read id: "); xil_printf("0x%08x\r\n", (unsigned)RP_ID); break;
        case 'x': load_partial(RM_A_ADDR); break;   /* raw load, no shutdown/decouple (for diagnosis) */
        case 'y': load_partial(RM_B_ADDR); break;
        case 'd': DEC_CTRL = 1; xil_printf("decoupled, control 0x%08x\r\n", (unsigned)DEC_CTRL); break;
        case 'e': DEC_CTRL = 0; xil_printf("coupled, control 0x%08x\r\n", (unsigned)DEC_CTRL); break;
        default: break;
        }
    }
}
