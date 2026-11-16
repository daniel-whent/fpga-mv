/*
 * Stage 1 hello world for the Nexys A7-100T MicroBlaze system.
 * Output goes through AXI UART Lite (stdout) to the board's USB-UART at 115200 8N1.
 */
#include <stdint.h>
#include "xil_printf.h"
#include "sleep.h"

int main(void)
{
    uint32_t count = 0;

    xil_printf("\r\nNexys A7-100T MicroBlaze hello world\r\n");

    while (1) {
        xil_printf("tick %u\r\n", (unsigned int)count++);
        sleep(1);
    }

    return 0;
}
