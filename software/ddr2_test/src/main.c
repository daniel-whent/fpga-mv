/*
 * Stage 2: DDR2 memory test for the Nexys A7-100T (MIG, 128 MiB at 0x80000000).
 *
 * Addresses come from the Stage 2 block design address map (scripts/create_bd_stage2.tcl prints it):
 *   AXI GPIO  0x40000000  ch1 = 16 LEDs (out), ch2 = status in: bit0 init_calib_complete, bit1 mmcm_locked
 *   MIG DDR2  0x80000000  128 MiB
 * Registers are accessed directly so the program does not depend on generated driver names.
 * MicroBlaze caches are disabled in this design, so every access goes to DDR2.
 *
 * Output: UART (COM port, 115200 8N1). LEDs: progress bar while testing, all on = pass, blinking = fail.
 */
#include <stdint.h>
#include "xil_printf.h"
#include "sleep.h"

#define GPIO_BASE   0x40000000u
#define GPIO_LED    (*(volatile uint32_t *)(GPIO_BASE + 0x00))
#define GPIO_STATUS (*(volatile uint32_t *)(GPIO_BASE + 0x08))
#define ST_CALIB    0x1u
#define ST_MMCM     0x2u

#define DDR_BASE    0x80000000u
#define DDR_SIZE    0x08000000u          /* 128 MiB */
#define DDR(a)      (*(volatile uint32_t *)(DDR_BASE + (a)))

#define FILL_BYTES  (4u * 1024u * 1024u) /* region for the fill/verify pass */

static unsigned errors;

static void fail(const char *what, uint32_t addr, uint32_t exp, uint32_t got)
{
    if (errors < 10)
        xil_printf("  FAIL %s @0x%08x expected 0x%08x got 0x%08x\r\n",
                   what, (unsigned)(DDR_BASE + addr), (unsigned)exp, (unsigned)got);
    errors++;
}

static void test_data_bus(void)
{
    xil_printf("Data bus (walking 1s and 0s)... ");
    unsigned before = errors;
    for (int i = 0; i < 32; i++) {
        uint32_t p = 1u << i;
        DDR(0) = p;        if (DDR(0) != p)  fail("walk1", 0, p, DDR(0));
        DDR(0) = ~p;       if (DDR(0) != ~p) fail("walk0", 0, ~p, DDR(0));
    }
    xil_printf("%s\r\n", errors == before ? "ok" : "ERRORS");
}

static void test_address_bus(void)
{
    xil_printf("Address bus (power-of-two offsets)... ");
    unsigned before = errors;
    /* word offsets 1,2,4,...; byte offset = word*4, up to just under 128 MiB */
    for (uint32_t off = 4; off < DDR_SIZE; off <<= 1)
        DDR(off) = 0xA5A50000u | (off >> 2);
    DDR(0) = 0xDEADBEEFu;
    for (uint32_t off = 4; off < DDR_SIZE; off <<= 1) {
        uint32_t exp = 0xA5A50000u | (off >> 2), got = DDR(off);
        if (got != exp) fail("addr", off, exp, got);
    }
    if (DDR(0) != 0xDEADBEEFu) fail("addr-base", 0, 0xDEADBEEFu, DDR(0));
    xil_printf("%s\r\n", errors == before ? "ok" : "ERRORS");
}

static void test_fill(uint32_t bytes)
{
    xil_printf("Fill/verify %u KiB (address pattern, then inverse)... ", (unsigned)(bytes / 1024));
    unsigned before = errors;
    uint32_t words = bytes / 4;
    for (uint32_t i = 0; i < words; i++) DDR(i * 4) = i * 2654435761u;       /* multiplicative hash */
    for (uint32_t i = 0; i < words; i++) {
        uint32_t exp = i * 2654435761u, got = DDR(i * 4);
        if (got != exp) fail("fill", i * 4, exp, got);
    }
    for (uint32_t i = 0; i < words; i++) DDR(i * 4) = ~(i * 2654435761u);
    for (uint32_t i = 0; i < words; i++) {
        uint32_t exp = ~(i * 2654435761u), got = DDR(i * 4);
        if (got != exp) fail("fill-inv", i * 4, exp, got);
        if ((i & 0x3FFFF) == 0) GPIO_LED = (1u << ((i * 16u) / words)) - 1u;  /* progress bar */
    }
    xil_printf("%s\r\n", errors == before ? "ok" : "ERRORS");
}

int main(void)
{
    xil_printf("\r\n=== Nexys A7-100T DDR2 test ===\r\n");
    GPIO_LED = 0;

    int t;
    for (t = 0; t < 50 && !(GPIO_STATUS & ST_CALIB); t++) usleep(100000);   /* wait up to 5 s */
    xil_printf("status = 0x%x  (mmcm_locked=%u init_calib_complete=%u)\r\n",
               (unsigned)GPIO_STATUS, (unsigned)!!(GPIO_STATUS & ST_MMCM), (unsigned)!!(GPIO_STATUS & ST_CALIB));
    if (!(GPIO_STATUS & ST_CALIB)) {
        xil_printf("DDR2 calibration did NOT complete. Not touching memory.\r\n");
        for (;;) { GPIO_LED = 0xAAAA; usleep(250000); GPIO_LED = 0x5555; usleep(250000); }
    }

    errors = 0;
    test_data_bus();
    test_address_bus();
    test_fill(FILL_BYTES);

    if (errors == 0) {
        xil_printf("RESULT: PASS\r\n");
        GPIO_LED = 0xFFFF;
        for (;;) usleep(1000000);
    }
    xil_printf("RESULT: FAIL (%u errors)\r\n", errors);
    for (;;) { GPIO_LED = 0xFFFF; usleep(150000); GPIO_LED = 0; usleep(150000); }
}
