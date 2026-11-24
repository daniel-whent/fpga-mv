/*
 * DFX stage 3: stream a frame through the reconfigurable partition and check the result on the MicroBlaze.
 *
 *   DDR2 SRC_ADDR --(AXI DMA MM2S)--> partition (RM A grayscale / RM B invert) --(AXI DMA S2MM)--> DDR2 DST_ADDR
 *
 * The partial bitstreams are put into DDR2 by the host (scripts/dfx/load_and_run.tcl): RM A at 0x87000000,
 * RM B at 0x87100000. Pixels are 3 bytes in the order G, B, R (as in the VGA frame buffer).
 *
 * Commands (115200 8N1 on the UART Lite):
 *   a / b   swap to RM A (grayscale) / RM B (invert), then run + verify a frame
 *   g       run one frame through the current module and verify it
 *   z       toggle the module's bypass register (stream passes through unchanged), then run + verify
 *   t       benchmark: 10 alternating swaps, prints bitstream-load and whole-swap times in microseconds
 *   f       refill the source frame with new pseudo-random data
 *   i       print module id, control and byte counter
 *   d / e   decouple / couple the partition (diagnosis)
 */
#include <stdint.h>
#include "xil_printf.h"
#include "sleep.h"

/* ---- addresses from the block design address map (printed by scripts/dfx/create_bd_rp_stream.tcl) */
#ifndef DEC_BASE
#define DEC_BASE 0x44A00000u      /* dfx_decoupler control */
#endif
#ifndef ASM_BASE
#define ASM_BASE 0x44A10000u      /* dfx_axi_shutdown_manager control */
#endif
#ifndef RP_BASE
#define RP_BASE  0x44A20000u      /* partition AXI4-Lite slave */
#endif
#ifndef RST_BASE
#define RST_BASE 0x40010000u      /* axi_gpio_rst: bit0 = partition reset released */
#endif
#ifndef HWICAP_BASE
#define HWICAP_BASE 0x40200000u
#endif
#ifndef DMA_BASE
#define DMA_BASE 0x41E00000u      /* axi_dma_rp */
#endif
#ifndef TIMER_BASE
#define TIMER_BASE 0x41C00000u    /* axi_timer_0, used as a free-running 100 MHz stopwatch */
#endif

#define DEC_CTRL  (*(volatile uint32_t *)(DEC_BASE + 0x0))
#define ASM_CTRL  (*(volatile uint32_t *)(ASM_BASE + 0x0))
#define RP_RST    (*(volatile uint32_t *)(RST_BASE + 0x0))
#define RP_CTRL   (*(volatile uint32_t *)(RP_BASE + 0x0))   /* bit0 = bypass */
#define RP_ID     (*(volatile uint32_t *)(RP_BASE + 0x4))
#define RP_COUNT  (*(volatile uint32_t *)(RP_BASE + 0x8))   /* input bytes seen; any write clears */
#define UART_RX   (*(volatile uint32_t *)0x40600000u)
#define UART_STAT (*(volatile uint32_t *)0x40600008u)

/* ---- stopwatch: AXI Timer 0 counting up at 100 MHz (10 ns per tick) */
#define TMR(off) (*(volatile uint32_t *)(TIMER_BASE + (off)))
static void timer_init(void)
{
    TMR(0x00) = 0;              /* stop */
    TMR(0x04) = 0;              /* load value 0 */
    TMR(0x00) = 0x20;           /* LOAD0 */
    TMR(0x00) = 0x80;           /* ENT0, count up, no interrupt */
}
static inline uint32_t now(void) { return TMR(0x08); }     /* ticks of 10 ns, wraps after 42.9 s */
#define US(t) ((unsigned)((t) / 100u))
#define US_FRAC(t) ((unsigned)(((t) % 100u)))

/* ---- HWICAP (see dfx_load) */
#define HW(off)   (*(volatile uint32_t *)(HWICAP_BASE + (off)))
#define HW_WF 0x100
#define HW_CR 0x10C
#define HW_SR 0x110
#define HW_WFV 0x114
#define CR_WRITE 0x1u
#define CR_FIFO_CLR 0x4u
#define CR_SW_RESET 0x8u
#define SR_DONE 0x1u
#define RM_A_ADDR 0x87000000u
#define RM_B_ADDR 0x87100000u

/* ---- AXI DMA (simple register mode) */
#define DMA(off)  (*(volatile uint32_t *)(DMA_BASE + (off)))
#define MM2S_CR 0x00
#define MM2S_SR 0x04
#define MM2S_SA 0x18
#define MM2S_LEN 0x28
#define S2MM_CR 0x30
#define S2MM_SR 0x34
#define S2MM_DA 0x48
#define S2MM_LEN 0x58

#define SRC_ADDR 0x80000000u
#define DST_ADDR 0x80200000u
#define FRAME_BYTES (640u * 480u * 3u)

static uint32_t rng = 12345u;
static uint8_t next_byte(void) { rng = rng * 1664525u + 1013904223u; return (uint8_t)(rng >> 24); }

static void fill_source(void)
{
    volatile uint8_t *s = (volatile uint8_t *)SRC_ADDR;
    for (uint32_t i = 0; i < FRAME_BYTES; i++) s[i] = next_byte();
    /* make sure the extremes are present */
    s[0] = 0; s[1] = 0; s[2] = 0; s[3] = 255; s[4] = 255; s[5] = 255;
    xil_printf("source frame filled (%u bytes at 0x%08x)\r\n", (unsigned)FRAME_BYTES, (unsigned)SRC_ADDR);
}

static void clear_dest(void)
{
    volatile uint32_t *d = (volatile uint32_t *)DST_ADDR;
    for (uint32_t i = 0; i < FRAME_BYTES / 4; i++) d[i] = 0xA5A5A5A5u;
}

/* run one frame through the partition; returns 0 when both DMA channels finished without error */
static int run_frame(uint32_t *ticks)
{
    clear_dest();
    DMA(MM2S_CR) = 4u; DMA(S2MM_CR) = 4u;                   /* reset both channels */
    while ((DMA(MM2S_CR) & 4u) || (DMA(S2MM_CR) & 4u)) { }
    DMA(MM2S_CR) = 1u; DMA(S2MM_CR) = 1u;                   /* run */
    RP_COUNT = 0;                                           /* clear the engine's byte counter */
    DMA(S2MM_DA)  = DST_ADDR;
    DMA(S2MM_LEN) = FRAME_BYTES;                            /* arm the receive side first */
    DMA(MM2S_SA)  = SRC_ADDR;
    DMA(MM2S_LEN) = FRAME_BYTES;                            /* starts the transfer */
    uint32_t t0 = now(), t = 0;
    while (!((DMA(MM2S_SR) & 2u) && (DMA(S2MM_SR) & 2u))) { t = now() - t0; if (t > 500000000u) break; }   /* 5 s */
    t = now() - t0;
    *ticks = t;
    uint32_t sr_m = DMA(MM2S_SR), sr_s = DMA(S2MM_SR);
    xil_printf("dma: mm2s sr=0x%08x s2mm sr=0x%08x, frame time %u us, engine counted %u bytes\r\n",
               (unsigned)sr_m, (unsigned)sr_s, US(t), (unsigned)RP_COUNT);
    if (t > 500000000u) { xil_printf("TIMEOUT waiting for the DMA\r\n"); return -1; }
    if ((sr_m | sr_s) & 0x70u) { xil_printf("DMA error bits set\r\n"); return -1; }
    return 0;
}

static void verify_frame(void)
{
    uint32_t id = RP_ID, bypass = RP_CTRL & 1u;
    volatile uint8_t *s = (volatile uint8_t *)SRC_ADDR, *d = (volatile uint8_t *)DST_ADDR;
    uint32_t bad = 0, first = 0xFFFFFFFFu;
    for (uint32_t p = 0; p < FRAME_BYTES / 3u; p++) {
        uint32_t g = s[3*p], b = s[3*p+1], r = s[3*p+2];
        uint8_t e[3];
        if (bypass)         { e[0] = g; e[1] = b; e[2] = r; }
        else if (id == 0xA) { uint8_t y = (uint8_t)((77u * r + 150u * g + 29u * b) >> 8); e[0] = e[1] = e[2] = y; }
        else                { e[0] = (uint8_t)~g; e[1] = (uint8_t)~b; e[2] = (uint8_t)~r; }
        for (int k = 0; k < 3; k++)
            if (d[3*p + k] != e[k]) { if (bad == 0) first = 3*p + k; bad++; }
    }
    xil_printf("VERIFY module 0x%x bypass %u: %u bad bytes of %u%s\r\n", (unsigned)id, (unsigned)bypass, (unsigned)bad,
               (unsigned)FRAME_BYTES, bad ? "  <<< FAIL" : "  OK");
    if (bad) xil_printf("  first bad byte at offset %d\r\n", (int)first);
}

static void run_and_verify(void)
{
    uint32_t t;
    if (run_frame(&t) == 0) verify_frame();
}

/* ---- partial reconfiguration (same sequence as dfx_load) */
static inline uint32_t bswap32(uint32_t v) { return (v >> 24) | ((v >> 8) & 0xFF00u) | ((v << 8) & 0xFF0000u) | (v << 24); }

static int load_partial(uint32_t addr)
{
    const volatile uint32_t *img = (const volatile uint32_t *)addr;
    uint32_t nwords = img[0];
    if (nwords == 0 || nwords > 0x40000u) { xil_printf("bad word count %u at 0x%08x\r\n", (unsigned)nwords, (unsigned)addr); return -1; }
    const volatile uint32_t *w = img + 1;
    HW(HW_CR) = CR_SW_RESET;  usleep(10);  HW(HW_CR) = 0;
    HW(HW_CR) = CR_FIFO_CLR;  usleep(10);  HW(HW_CR) = 0;
    uint32_t done_words = 0;
    while (done_words < nwords) {
        uint32_t vac = HW(HW_WFV);
        if (vac > nwords - done_words) vac = nwords - done_words;
        for (uint32_t i = 0; i < vac; i++) HW(HW_WF) = bswap32(w[done_words + i]);
        HW(HW_CR) = CR_WRITE;
        while (HW(HW_CR) & CR_WRITE) { }
        done_words += vac;
    }
    while (!(HW(HW_SR) & SR_DONE)) { }
    return 0;
}

static int asm_shutdown(void)
{
    ASM_CTRL = 1;
    for (int i = 0; i < 100000; i++) if (ASM_CTRL & 0x2u) return 0;
    xil_printf("shutdown manager did not reach shutdown, state 0x%x\r\n", (unsigned)ASM_CTRL);
    return -1;
}

/* shut down the AXI4-Lite bus, decouple (this also idles both stream interfaces), load, reset, re-couple */
static uint32_t last_load_ticks, last_swap_ticks;
static int swap_to(uint32_t addr)
{
    uint32_t t0 = now();
    if (asm_shutdown() != 0) { ASM_CTRL = 0; return -1; }
    DEC_CTRL = 1;
    uint32_t t1 = now();
    int rc = load_partial(addr);
    uint32_t t2 = now();
    RP_RST = 0; usleep(10); RP_RST = 1; usleep(10);     /* partial bitstreams do not initialize the flip-flops */
    DEC_CTRL = 0;
    ASM_CTRL = 0;
    uint32_t t3 = now();
    last_load_ticks = t2 - t1;
    last_swap_ticks = t3 - t0;
    if (rc == 0) xil_printf("module id 0x%08x   swap %u us total, of which bitstream load %u us\r\n",
                            (unsigned)RP_ID, US(last_swap_ticks), US(last_load_ticks));
    return rc;
}

/* benchmark: 10 alternating swaps without frames; min / average / max of the bitstream load and of the whole swap */
static void bench_swaps(void)
{
    uint32_t lmin = 0xFFFFFFFFu, lmax = 0, smin = 0xFFFFFFFFu, smax = 0;
    uint64_t lsum = 0, ssum = 0;
    for (int i = 0; i < 10; i++) {
        if (swap_to(i % 2 == 0 ? RM_B_ADDR : RM_A_ADDR) != 0) return;
        if (last_load_ticks < lmin) lmin = last_load_ticks;
        if (last_load_ticks > lmax) lmax = last_load_ticks;
        if (last_swap_ticks < smin) smin = last_swap_ticks;
        if (last_swap_ticks > smax) smax = last_swap_ticks;
        lsum += last_load_ticks; ssum += last_swap_ticks;
    }
    xil_printf("BENCH 10 swaps: bitstream load min %u avg %u max %u us; whole swap min %u avg %u max %u us\r\n",
               US(lmin), US((uint32_t)(lsum / 10)), US(lmax), US(smin), US((uint32_t)(ssum / 10)), US(smax));
}

static void info(void)
{
    xil_printf("module id 0x%08x  control 0x%08x  byte counter %u  decoupler 0x%08x\r\n",
               (unsigned)RP_ID, (unsigned)RP_CTRL, (unsigned)RP_COUNT, (unsigned)DEC_CTRL);
}

int main(void)
{
    xil_printf("\r\n=== DFX: streaming partition (grayscale / invert) ===\r\n");
    timer_init();
    DEC_CTRL = 0;
    fill_source();
    info();
    xil_printf("Commands: a/b swap to RM A (gray) / RM B (invert) and test, g test, z toggle bypass and test, f new source, i info, d/e decouple/couple\r\n");
    for (;;) {
        if (!(UART_STAT & 1u)) continue;
        switch ((char)(UART_RX & 0xFF)) {
        case 'a': if (swap_to(RM_A_ADDR) == 0) run_and_verify(); break;
        case 'b': if (swap_to(RM_B_ADDR) == 0) run_and_verify(); break;
        case 'g': run_and_verify(); break;
        case 'z': RP_CTRL = RP_CTRL ^ 1u; info(); run_and_verify(); break;
        case 'f': fill_source(); break;
        case 't': bench_swaps(); break;
        case 'i': info(); break;
        case 'd': DEC_CTRL = 1; xil_printf("decoupled\r\n"); break;
        case 'e': DEC_CTRL = 0; xil_printf("coupled\r\n"); break;
        default: break;
        }
    }
}
