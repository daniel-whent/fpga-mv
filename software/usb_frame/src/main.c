/*
 * Stage 4: receive frames from the PC over the USB-UART bridge at 4 Mbaud into the DDR2 framebuffer.
 * The VDMA keeps scanning the framebuffer out to VGA, so a frame appears on the monitor as it arrives.
 *
 * Commands on the 115200 UART (AXI UART Lite):
 *   'F' + 3 bytes (little-endian byte count)  arm the DMA for that many bytes, reply "R\n"; the PC then switches the
 *                                             port to 4 Mbaud and streams the bytes; reply "D <rx status> <dma sr>\n"
 *   b  color bars    k  black    s  status
 * Addresses from the Stage 4 block design: GPIO(LED/status) 0x40000000, GPIO usb 0x40010000 (ctrl +0, status +8),
 * UART Lite 0x40600000, AXI DMA 0x41E00000, VDMA 0x44A00000, DDR2 0x80000000.
 */
#include <stdint.h>
#include "xil_printf.h"
#include "sleep.h"

#define GPIO_BASE   0x40000000u
#define GPIO_LED    (*(volatile uint32_t *)(GPIO_BASE + 0x00))
#define GPIO_STATUS (*(volatile uint32_t *)(GPIO_BASE + 0x08))

#define USB_CTRL    (*(volatile uint32_t *)0x40010000u)
#define USB_STATUS  (*(volatile uint32_t *)0x40010008u)   /* [0] overflow [1] done [2] framing err [31:8] byte count */

#define UART_RX     (*(volatile uint32_t *)0x40600000u)
#define UART_STAT   (*(volatile uint32_t *)0x40600008u)

#define DMA_BASE    0x41E00000u
#define DMA(off)    (*(volatile uint32_t *)(DMA_BASE + (off)))
#define S2MM_CR     0x30
#define S2MM_SR     0x34
#define S2MM_DA     0x48
#define S2MM_LENGTH 0x58

#define VDMA_BASE        0x44A00000u
#define VDMA(off)        (*(volatile uint32_t *)(VDMA_BASE + (off)))
#define MM2S_VDMACR      0x00
#define PARK_PTR_REG     0x28
#define MM2S_VSIZE       0x50
#define MM2S_HSIZE       0x54
#define MM2S_FRMDLY_STRIDE 0x58
#define MM2S_START_ADDR0 0x5C

#define FB_BASE   0x80000000u
#define WIDTH     640u
#define HEIGHT    480u
#define STRIDE    (WIDTH * 3u)

static void start_vdma(void)
{
    VDMA(MM2S_VDMACR) = 4u;                          /* reset */
    while (VDMA(MM2S_VDMACR) & 4u) { }
    VDMA(MM2S_VDMACR)        = 1u;                   /* run, park mode */
    VDMA(PARK_PTR_REG)       = 0;
    VDMA(MM2S_START_ADDR0)   = FB_BASE;
    VDMA(MM2S_FRMDLY_STRIDE) = STRIDE;
    VDMA(MM2S_HSIZE)         = STRIDE;
    VDMA(MM2S_VSIZE)         = HEIGHT;
}

static void put_px(uint32_t x, uint32_t y, uint8_t r, uint8_t g, uint8_t b)
{
    volatile uint8_t *p = (volatile uint8_t *)(FB_BASE + y * STRIDE + x * 3u);
    p[0] = g; p[1] = b; p[2] = r;
}

static void draw_bars(void)
{
    static const uint8_t bars[8][3] = {
        {255,255,255}, {255,255,0}, {0,255,255}, {0,255,0}, {255,0,255}, {255,0,0}, {0,0,255}, {0,0,0},
    };
    for (uint32_t y = 0; y < HEIGHT; y++)
        for (uint32_t x = 0; x < WIDTH; x++) {
            if (x < 4 || x >= WIDTH - 4 || y < 4 || y >= HEIGHT - 4) put_px(x, y, 255, 255, 255);
            else if (y < (HEIGHT * 2) / 3) { const uint8_t *c = bars[x / (WIDTH / 8)]; put_px(x, y, c[0], c[1], c[2]); }
            else { uint8_t v = (uint8_t)((x * 256u) / WIDTH); put_px(x, y, v, v, v); }
        }
}

static void fill_black(void)
{
    volatile uint32_t *p = (volatile uint32_t *)FB_BASE;
    for (uint32_t i = 0; i < (WIDTH * HEIGHT * 3u) / 4u; i++) p[i] = 0;
}

static void print_status(void)
{
    uint32_t u = USB_STATUS;
    xil_printf("usb rx: count=%u overflow=%u done=%u framing=%u | dma sr=0x%08x | vdma sr=0x%08x\r\n",
               (unsigned)(u >> 8), (unsigned)(u & 1), (unsigned)((u >> 1) & 1), (unsigned)((u >> 2) & 1),
               (unsigned)DMA(S2MM_SR), (unsigned)VDMA(0x04));
}

static uint8_t uart_getc(void)
{
    while (!(UART_STAT & 1u)) { }
    return (uint8_t)(UART_RX & 0xFF);
}

static void receive_frame(uint32_t len)
{
    if (len == 0 || len > WIDTH * HEIGHT * 3u) { xil_printf("bad length %u\r\n", (unsigned)len); return; }

    USB_CTRL = 0;                                   /* receiver disabled, flags cleared on the next enable */
    DMA(S2MM_CR) = 4u;                              /* DMA reset */
    while (DMA(S2MM_CR) & 4u) { }
    DMA(S2MM_CR) = 1u;                              /* run */
    DMA(S2MM_DA) = FB_BASE;
    DMA(S2MM_LENGTH) = len;                         /* arms the transfer */
    USB_CTRL = 0x80000000u | len;                   /* enable receiver for exactly len bytes */
    xil_printf("R\r\n");

    /* wait for the DMA to finish (the PC switches baud, then streams ~len*10/4e6 s) */
    uint32_t waited = 0;
    while (!(DMA(S2MM_SR) & 0x2u) && waited < 60000u) { usleep(1000); waited++; }   /* IDLE bit */
    uint32_t u = USB_STATUS;
    USB_CTRL = 0;
    xil_printf("D 0x%08x 0x%08x\r\n", (unsigned)u, (unsigned)DMA(S2MM_SR));
}

int main(void)
{
    xil_printf("\r\n=== Nexys A7: USB frame receiver ===\r\n");
    GPIO_LED = 0;
    for (int t = 0; t < 50 && !(GPIO_STATUS & 0x1u); t++) usleep(100000);
    if (!(GPIO_STATUS & 0x1u)) { xil_printf("DDR2 not calibrated\r\n"); for (;;) { } }

    draw_bars();
    start_vdma();
    GPIO_LED = 0xFFFF;
    xil_printf("Ready. 'F'+3 length bytes = receive frame at 4 Mbaud; b bars, k black, s status\r\n");

    for (;;) {
        if (!(UART_STAT & 1u)) continue;
        char c = (char)(UART_RX & 0xFF);
        switch (c) {
        case 'F': {
            uint32_t len = uart_getc();
            len |= (uint32_t)uart_getc() << 8;
            len |= (uint32_t)uart_getc() << 16;
            receive_frame(len);
            break;
        }
        case 'b': draw_bars();  xil_printf("done\r\n"); break;
        case 'k': fill_black(); xil_printf("done\r\n"); break;
        case 's': print_status(); break;
        default: break;
        }
    }
}
