/* spi_lcd.c — minimal ST7789v2 hardware driver for fleet_display.rail
   Compile on Pi: gcc -o spi_lcd spi_lcd.c -lm
   Usage: spi_lcd init | spi_lcd push <rgb565_file> | spi_lcd bl <0|1>
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/spi/spidev.h>

#define DC  537
#define RST 539
#define BL  530
#define W 240
#define H 280
#define Y_OFF 20

static int spi_fd = -1;

static void gpio_export(int pin) {
    char buf[64];
    FILE *f = fopen("/sys/class/gpio/export", "w");
    if (f) { fprintf(f, "%d", pin); fclose(f); }
    usleep(50000);
    snprintf(buf, sizeof(buf), "/sys/class/gpio/gpio%d/direction", pin);
    f = fopen(buf, "w"); if (f) { fprintf(f, "out"); fclose(f); }
}

static void gpio_set(int pin, int val) {
    char buf[64];
    snprintf(buf, sizeof(buf), "/sys/class/gpio/gpio%d/value", pin);
    FILE *f = fopen(buf, "w");
    if (f) { fprintf(f, "%d", val); fclose(f); }
}

static void spi_init(void) {
    spi_fd = open("/dev/spidev0.0", O_RDWR);
    unsigned char mode = 0;
    unsigned int speed = 62500000;
    unsigned char bits = 8;
    ioctl(spi_fd, SPI_IOC_WR_MODE, &mode);
    ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed);
    ioctl(spi_fd, SPI_IOC_WR_BITS_PER_WORD, &bits);
}

static void spi_cmd(unsigned char c) {
    gpio_set(DC, 0);
    write(spi_fd, &c, 1);
}

static void spi_data_byte(unsigned char d) {
    gpio_set(DC, 1);
    write(spi_fd, &d, 1);
}

static void spi_data_buf(unsigned char *buf, int len) {
    gpio_set(DC, 1);
    for (int i = 0; i < len; i += 4096) {
        int chunk = (len - i < 4096) ? (len - i) : 4096;
        write(spi_fd, buf + i, chunk);
    }
}

static void spi_data16(unsigned short v) {
    unsigned char b[2] = { v >> 8, v & 0xFF };
    gpio_set(DC, 1);
    write(spi_fd, b, 2);
}

static void set_window(int x0, int y0, int x1, int y1) {
    spi_cmd(0x2A);
    spi_data16(x0); spi_data16(x1);
    spi_cmd(0x2B);
    spi_data16(y0 + Y_OFF); spi_data16(y1 + Y_OFF);
}

static void display_init(void) {
    gpio_export(DC); gpio_export(RST); gpio_export(BL);
    gpio_set(BL, 1);
    spi_init();
    gpio_set(RST, 1); usleep(10000);
    gpio_set(RST, 0); usleep(10000);
    gpio_set(RST, 1); usleep(120000);
    spi_cmd(0x01); usleep(150000);  /* SWRESET */
    spi_cmd(0x11); usleep(500000);  /* SLPOUT */
    spi_cmd(0x3A); spi_data_byte(0x55);  /* COLMOD 16-bit */
    spi_cmd(0x36); spi_data_byte(0x00);  /* MADCTL */
    spi_cmd(0x21);  /* INVON */
    spi_cmd(0x13);  /* NORON */
    usleep(10000);
    spi_cmd(0x29);  /* DISPON */
    usleep(100000);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "Usage: spi_lcd init|push <file>|bl <0|1>|fill <r> <g> <b>\n"); return 1; }

    if (strcmp(argv[1], "init") == 0) {
        display_init();
        printf("OK\n");
    }
    else if (strcmp(argv[1], "push") == 0 && argc >= 3) {
        /* Push RGB565 framebuffer file to display */
        spi_fd = open("/dev/spidev0.0", O_RDWR);
        unsigned char mode = 0; unsigned int speed = 62500000; unsigned char bits = 8;
        ioctl(spi_fd, SPI_IOC_WR_MODE, &mode);
        ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed);
        ioctl(spi_fd, SPI_IOC_WR_BITS_PER_WORD, &bits);

        FILE *f = fopen(argv[2], "rb");
        if (!f) { fprintf(stderr, "Cannot open %s\n", argv[2]); return 1; }
        unsigned char *buf = malloc(W * H * 2);
        int n = fread(buf, 1, W * H * 2, f);
        fclose(f);

        set_window(0, 0, W-1, H-1);
        spi_cmd(0x2C);  /* RAMWR */
        spi_data_buf(buf, n);
        free(buf);
    }
    else if (strcmp(argv[1], "bl") == 0 && argc >= 3) {
        gpio_set(BL, atoi(argv[2]));
    }
    else if (strcmp(argv[1], "fill") == 0 && argc >= 5) {
        /* Fill screen with solid color (RGB) */
        spi_fd = open("/dev/spidev0.0", O_RDWR);
        unsigned char mode = 0; unsigned int speed = 62500000; unsigned char bits = 8;
        ioctl(spi_fd, SPI_IOC_WR_MODE, &mode);
        ioctl(spi_fd, SPI_IOC_WR_MAX_SPEED_HZ, &speed);
        ioctl(spi_fd, SPI_IOC_WR_BITS_PER_WORD, &bits);

        int r = atoi(argv[2]), g = atoi(argv[3]), b = atoi(argv[4]);
        unsigned short rgb565 = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3);
        unsigned char *buf = malloc(W * H * 2);
        for (int i = 0; i < W * H; i++) { buf[i*2] = rgb565 >> 8; buf[i*2+1] = rgb565 & 0xFF; }

        set_window(0, 0, W-1, H-1);
        spi_cmd(0x2C);
        spi_data_buf(buf, W * H * 2);
        free(buf);
    }
    return 0;
}
