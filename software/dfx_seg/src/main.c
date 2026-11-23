/*
 * DFX warm-up, milestone 1: drive the reconfigurable partition's input from software and read its output.
 * GPIO "rp" at 0x40010000: channel 1 (offset 0x00) = value written INTO the partition (rp_din),
 *                          channel 2 (offset 0x08) = value coming OUT of the partition (rp_dout),
 * which is also what the strobed 7-segment display shows as 8 hex digits.
 *
 * UART commands: 0 = 0x12345678, 1 = 0xDEADBEEF, 2 = 0x01234567, 3 = 0x89ABCDEF, c = count up, p = print.
 * Module A (pass-through) shows the value as written; module B (halves swapped) shows 0x56781234 for 0x12345678.
 */
#include <stdint.h>
#include "xil_printf.h"
#include "sleep.h"

#define RP_IN   (*(volatile uint32_t *)0x40010000u)
#define RP_OUT  (*(volatile uint32_t *)0x40010008u)
#define UART_RX   (*(volatile uint32_t *)0x40600000u)
#define UART_STAT (*(volatile uint32_t *)0x40600008u)

static void show(uint32_t v)
{
    RP_IN = v;
    usleep(1000);
    xil_printf("wrote 0x%08x  partition output 0x%08x\r\n", (unsigned)v, (unsigned)RP_OUT);
}

int main(void)
{
    xil_printf("\r\n=== DFX warm-up: reconfigurable partition test ===\r\n");
    show(0x12345678u);
    xil_printf("Commands: 0 1 2 3 = fixed values, c = count 0..63, p = print\r\n");
    for (;;) {
        if (!(UART_STAT & 1u)) continue;
        switch ((char)(UART_RX & 0xFF)) {
        case '0': show(0x12345678u); break;
        case '1': show(0xDEADBEEFu); break;
        case '2': show(0x01234567u); break;
        case '3': show(0x89ABCDEFu); break;
        case 'c': for (uint32_t i = 0; i < 64; i++) { RP_IN = i * 0x01010101u; usleep(100000); } show(RP_IN); break;
        case 'p': xil_printf("din 0x%08x dout 0x%08x\r\n", (unsigned)RP_IN, (unsigned)RP_OUT); break;
        default: break;
        }
    }
}
