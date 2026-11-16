/*
 * Stage 3: VGA test / diagnostic harness. Draws patterns into a DDR2 framebuffer and runs the AXI VDMA
 * to scan it out (640x480, 24 bits/pixel packed, 1920 bytes/line). Patterns are chosen over the UART
 * (115200 8N1) with single characters:
 *
 *   b  color bars (white yellow cyan green magenta red blue black) + gray ramp + white border (default)
 *   r  solid red        g  solid green      u  solid blue      w  solid white      k  solid black
 *   l  alternating lines: even lines white, odd lines black
 *   x  alternating pixels: even columns white, odd columns black
 *   h  left half white, right half black       v  top half white, bottom half black
 *   R  solid red drawn slowly with byte stores   T  solid red, fast word stores but throttled (pause per line)
 *   d  dump framebuffer words (line 0 and line 100) and the VDMA registers
 *   s  print VDMA status
 *   z  stop VDMA   a  restart VDMA
 *
 * Pixel layout in memory: byte0 = G, byte1 = B, byte2 = R (Xilinx "RGB" stream order
 * tdata[23:16]=R, [15:8]=B, [7:0]=G). Addresses are from the Stage 3 block design:
 *   AXI GPIO 0x40000000, AXI UART Lite 0x40600000, AXI VDMA 0x44A00000, DDR2 0x80000000.
 */
#include <stdint.h>
#include "xil_printf.h"
#include "sleep.h"

#define GPIO_BASE   0x40000000u
#define GPIO_LED    (*(volatile uint32_t *)(GPIO_BASE + 0x00))
#define GPIO_STATUS (*(volatile uint32_t *)(GPIO_BASE + 0x08))

#define UART_BASE   0x40600000u
#define UART_RX     (*(volatile uint32_t *)(UART_BASE + 0x00))
#define UART_STAT   (*(volatile uint32_t *)(UART_BASE + 0x08))
#define UART_RXVALID 0x1u

#define VDMA_BASE        0x44A00000u
#define VDMA(off)        (*(volatile uint32_t *)(VDMA_BASE + (off)))
#define MM2S_VDMACR      0x00
#define MM2S_VDMASR      0x04
#define PARK_PTR_REG     0x28
#define MM2S_VSIZE       0x50
#define MM2S_HSIZE       0x54
#define MM2S_FRMDLY_STRIDE 0x58
#define MM2S_START_ADDR0 0x5C

#define CR_RUN           (1u << 0)
#define CR_RESET         (1u << 2)

#define FB_BASE   0x80000000u
#define WIDTH     640u
#define HEIGHT    480u
#define BPP       3u
#define STRIDE    (WIDTH * BPP)       /* 1920 bytes: a multiple of 16 */

static inline void put_px(uint32_t x, uint32_t y, uint8_t r, uint8_t g, uint8_t b)
{
    volatile uint8_t *p = (volatile uint8_t *)(FB_BASE + y * STRIDE + x * BPP);
    p[0] = g;
    p[1] = b;
    p[2] = r;
}

/* Fast solid fill: 4 pixels = 12 bytes = 3 little-endian words. */
static void fill_solid(uint8_t r, uint8_t g, uint8_t b)
{
    uint32_t w0 = g | (uint32_t)b << 8 | (uint32_t)r << 16 | (uint32_t)g << 24;
    uint32_t w1 = b | (uint32_t)r << 8 | (uint32_t)g << 16 | (uint32_t)b << 24;
    uint32_t w2 = r | (uint32_t)g << 8 | (uint32_t)b << 16 | (uint32_t)r << 24;
    volatile uint32_t *p = (volatile uint32_t *)FB_BASE;
    for (uint32_t i = 0; i < (WIDTH * HEIGHT) / 4; i++) {
        p[3 * i]     = w0;
        p[3 * i + 1] = w1;
        p[3 * i + 2] = w2;
    }
}

/* Solid red drawn pixel by pixel with byte stores (slow, like the mono patterns). */
static void fill_red_slow(void)
{
    for (uint32_t y = 0; y < HEIGHT; y++)
        for (uint32_t x = 0; x < WIDTH; x++)
            put_px(x, y, 255, 0, 0);
}

/* Same word-store fill as fill_solid(), but pause after every line so the CPU does not hog DDR2. */
static void fill_red_throttled(void)
{
    uint32_t w0 = 0x00FF0000u, w1 = 0x0000FF00u, w2 = 0xFF0000FFu;   /* red, 4 px per 3 words */
    volatile uint32_t *p = (volatile uint32_t *)FB_BASE;
    for (uint32_t y = 0; y < HEIGHT; y++) {
        for (uint32_t i = 0; i < WIDTH / 4; i++) {
            p[3 * i]     = w0;
            p[3 * i + 1] = w1;
            p[3 * i + 2] = w2;
        }
        p += STRIDE / 4;
        usleep(2000);
    }
}

static void draw_bars(void)
{
    static const uint8_t bars[8][3] = {
        {255,255,255}, {255,255,0}, {0,255,255}, {0,255,0},
        {255,0,255},   {255,0,0},   {0,0,255},   {0,0,0},
    };
    for (uint32_t y = 0; y < HEIGHT; y++) {
        for (uint32_t x = 0; x < WIDTH; x++) {
            uint8_t r, g, b;
            if (x < 4 || x >= WIDTH - 4 || y < 4 || y >= HEIGHT - 4) {
                r = g = b = 255;
            } else if (y < (HEIGHT * 2) / 3) {
                const uint8_t *c = bars[x / (WIDTH / 8)];
                r = c[0]; g = c[1]; b = c[2];
            } else {
                r = g = b = (uint8_t)((x * 256u) / WIDTH);
            }
            put_px(x, y, r, g, b);
        }
    }
}

/* mode: 'l' lines, 'x' columns, 'h' left/right halves, 'v' top/bottom halves */
static void draw_mono(char mode)
{
    for (uint32_t y = 0; y < HEIGHT; y++) {
        for (uint32_t x = 0; x < WIDTH; x++) {
            int white;
            switch (mode) {
            case 'l': white = !(y & 1); break;
            case 'x': white = !(x & 1); break;
            case 'h': white = x < WIDTH / 2; break;
            default:  white = y < HEIGHT / 2; break;
            }
            uint8_t v = white ? 255 : 0;
            put_px(x, y, v, v, v);
        }
    }
}

static void start_vdma(void)
{
    VDMA(MM2S_VDMACR) = CR_RESET;
    while (VDMA(MM2S_VDMACR) & CR_RESET) { }
    VDMA(MM2S_VDMACR)        = CR_RUN;               /* run, park mode */
    VDMA(PARK_PTR_REG)       = 0;
    VDMA(MM2S_START_ADDR0)   = FB_BASE;
    VDMA(MM2S_FRMDLY_STRIDE) = STRIDE;
    VDMA(MM2S_HSIZE)         = STRIDE;
    VDMA(MM2S_VSIZE)         = HEIGHT;               /* writing VSIZE starts the transfer */
}

/* GPIO status bits: 0 init_calib_complete, 1 mmcm_locked, 2 vid_out locked, 3 underflow, 4 overflow */
static void print_flags(void)
{
    uint32_t s = GPIO_STATUS;
    xil_printf("flags: calib=%u mmcm=%u vo_locked=%u underflow=%u overflow=%u (raw 0x%02x)\r\n",
               (unsigned)(s & 1), (unsigned)((s >> 1) & 1), (unsigned)((s >> 2) & 1),
               (unsigned)((s >> 3) & 1), (unsigned)((s >> 4) & 1), (unsigned)s);
}

static void print_status(void)
{
    print_flags();
    xil_printf("VDMACR=0x%08x VDMASR=0x%08x PARK=0x%08x START0=0x%08x STRIDE=0x%08x HSIZE=0x%08x VSIZE=0x%08x\r\n",
               (unsigned)VDMA(MM2S_VDMACR), (unsigned)VDMA(MM2S_VDMASR), (unsigned)VDMA(PARK_PTR_REG),
               (unsigned)VDMA(MM2S_START_ADDR0), (unsigned)VDMA(MM2S_FRMDLY_STRIDE),
               (unsigned)VDMA(MM2S_HSIZE), (unsigned)VDMA(MM2S_VSIZE));
}

static void dump_words(const char *label, uint32_t byte_off, int n)
{
    xil_printf("%s (byte offset %u):", label, (unsigned)byte_off);
    for (int i = 0; i < n; i++)
        xil_printf(" %08x", (unsigned)*(volatile uint32_t *)(FB_BASE + byte_off + 4u * i));
    xil_printf("\r\n");
}

static void do_dump(void)
{
    dump_words("line 0  ", 0, 12);
    dump_words("line 100", 100u * STRIDE, 12);
    dump_words("line 100 x=80", 100u * STRIDE + 80u * BPP - 8u, 6);
    print_status();
}

static void apply(char c)
{
    switch (c) {
    case 'b': xil_printf("pattern: color bars\r\n");       draw_bars();                 break;
    case 'r': xil_printf("pattern: solid red\r\n");        fill_solid(255, 0, 0);       break;
    case 'g': xil_printf("pattern: solid green\r\n");      fill_solid(0, 255, 0);       break;
    case 'u': xil_printf("pattern: solid blue\r\n");       fill_solid(0, 0, 255);       break;
    case 'w': xil_printf("pattern: solid white\r\n");      fill_solid(255, 255, 255);   break;
    case 'k': xil_printf("pattern: solid black\r\n");      fill_solid(0, 0, 0);         break;
    case 'l': xil_printf("pattern: alternating lines\r\n");  draw_mono('l');            break;
    case 'x': xil_printf("pattern: alternating pixels\r\n"); draw_mono('x');            break;
    case 'h': xil_printf("pattern: left/right halves\r\n");  draw_mono('h');            break;
    case 'v': xil_printf("pattern: top/bottom halves\r\n");  draw_mono('v');            break;
    case 'R': xil_printf("pattern: solid red, slow byte stores\r\n"); fill_red_slow();   break;
    case 'T': xil_printf("pattern: solid red, throttled word stores\r\n"); fill_red_throttled(); break;
    case 'd': do_dump();                                                                 break;
    case 's': print_status();                                                            break;
    case 'z': VDMA(MM2S_VDMACR) = 0; xil_printf("vdma stopped\r\n");                     break;
    case 'a': start_vdma(); xil_printf("vdma restarted\r\n");                            break;
    default:  break;
    }
    if (c != 'd' && c != 's' && c != 'z' && c != 'a') xil_printf("done\r\n");
}

int main(void)
{
    xil_printf("\r\n=== Nexys A7-100T VGA diagnostic harness ===\r\n");
    GPIO_LED = 0;

    /* After a reset MIG needs a moment to calibrate; wait up to 5 s before giving up. */
    for (int t = 0; t < 50 && !(GPIO_STATUS & 0x1u); t++) usleep(100000);
    if (!(GPIO_STATUS & 0x1u)) {
        xil_printf("DDR2 not calibrated (status=0x%x). Aborting.\r\n", (unsigned)GPIO_STATUS);
        for (;;) { GPIO_LED = 0xAAAA; usleep(250000); GPIO_LED = 0x5555; usleep(250000); }
    }

    apply('b');
    start_vdma();
    GPIO_LED = 0xFFFF;
    print_status();
    xil_printf("Ready. Commands: b r g u w k l x h v  d s z a\r\n");

    for (;;) {
        if (UART_STAT & UART_RXVALID)
            apply((char)(UART_RX & 0xFF));
    }
}
