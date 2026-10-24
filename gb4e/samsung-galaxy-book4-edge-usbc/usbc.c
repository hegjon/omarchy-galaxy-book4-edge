// SPDX-License-Identifier: GPL-2.0
/*
 * USB-C power roles for the Samsung Galaxy Book4 Edge 14.
 *
 * Each USB-C port has a Samsung S2MM006 PD controller at 0x33 on its own I2C
 * bus (i2c@a84000: port 0, i2c@a9c000: port 1). After boot the controller
 * only detects a new partner and then waits for the host, which on Windows is
 * EmuEc.sys. Linux has no driver for it, so this does the same:
 *
 *  - a device (sink) is detected but gets no VBUS: command 0x09, provider on
 *  - a device we power is removed: command 0x00, all switches off (else VBUS
 *    stays on and a charger plugged in next can't attach)
 *  - a charger (source) attaches but its input switch stays open: command
 *    0x12, consumer on; then ask for the highest fixed PDO up to 20 V, at
 *    most twice per attach
 *
 * The commands are EmuEc.sys's: its switch function writes 0x00, 0x09 or 0x12
 * to register 0x4E. Registers are 16-bit. Others used here, from
 * ciscobugger/book4-edge-linux (reports/ec/07-pdic-s2mm006.md) and tests on
 * this machine: 0x0E attach (bit 4 a sink partner, 0x10 while it waits for
 * VBUS; bits 1-3 a source partner; 0x01 alone shows up for both and is never
 * acted on; 0x05 with the provider on: the device is gone), 0x1C switches
 * (bit 0 provider, 0x0a consumer closed), 0x0900 the received
 * Source_Capabilities (empty without a source), 0x0080 the message to send,
 * 0x50 bit 6 sends it, 0x06A0 the Request in force.
 */
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>

#define ADDR		0x33
#define POLL_MS		150	/* a waiting device shows 0x10 for ~0.33 s of every ~3.7 s */
#define SETTLE		1.0	/* s after a command before acting on that port again */
#define GONE_POLLS	3	/* polls a powered port must look empty before VBUS goes off */
#define MAX_MV		20000	/* the charger's input limit */
#define MAX_TX		2	/* PD transmissions per attach */
#define TX_GAP		30.0	/* s between transmissions, any port */

struct port {
	int n, fd, gone, tx;
	double cmd_t, check_t;
};

static double last_tx = -TX_GAP;

static double now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* I2C bus numbers follow probe order, so find the controller by address. */
static int bus_of(const char *controller)
{
	char path[PATH_MAX], real[PATH_MAX], want[64];
	struct dirent *e;
	DIR *d = opendir("/sys/bus/i2c/devices");
	int bus = -1;

	if (!d)
		return -1;
	snprintf(want, sizeof(want), "/%s.i2c/", controller);
	while (bus < 0 && (e = readdir(d))) {
		if (strncmp(e->d_name, "i2c-", 4))
			continue;
		snprintf(path, sizeof(path), "/sys/bus/i2c/devices/%s", e->d_name);
		if (!realpath(path, real))
			continue;
		strncat(real, "/", sizeof(real) - strlen(real) - 1);
		if (strstr(real, want))
			bus = atoi(e->d_name + 4);
	}
	closedir(d);
	return bus;
}

static int xfer(struct port *p, uint8_t *w, int wlen, uint8_t *r, int rlen)
{
	struct i2c_msg msgs[2] = {
		{ .addr = ADDR, .flags = 0, .len = wlen, .buf = w },
		{ .addr = ADDR, .flags = I2C_M_RD, .len = rlen, .buf = r },
	};
	struct i2c_rdwr_ioctl_data data = { .msgs = msgs, .nmsgs = rlen ? 2 : 1 };

	return ioctl(p->fd, I2C_RDWR, &data) < 0 ? -1 : 0;
}

static int rd(struct port *p, uint16_t reg, uint8_t *buf, int n)
{
	uint8_t a[2] = { reg >> 8, reg & 0xff };

	return xfer(p, a, 2, buf, n);
}

static int rd1(struct port *p, uint16_t reg)
{
	uint8_t v;

	return rd(p, reg, &v, 1) ? -1 : v;
}

static int wr(struct port *p, uint16_t reg, uint8_t val)
{
	uint8_t a[3] = { reg >> 8, reg & 0xff, val };

	return xfer(p, a, 3, NULL, 0);
}

static void command(struct port *p, uint8_t val, const char *what, int a, int s)
{
	if (wr(p, 0x4E, val))
		return;
	p->cmd_t = now();
	printf("port %d: %s (0x0E=0x%02x 0x1C=0x%02x)\n", p->n, what, a, s);
}

/* PDOs of the received Source_Capabilities; returns how many (0: none). */
static int caps(struct port *p, uint32_t pdo[7])
{
	uint8_t b[32];
	int h, n, i;

	if (rd(p, 0x0900, b, sizeof(b)))
		return 0;
	h = b[0] | b[1] << 8;
	n = h >> 12 & 7;
	if ((h & 0xf) != 1)
		return 0;
	for (i = 0; i < n; i++)
		pdo[i] = b[4 + 4 * i] | b[5 + 4 * i] << 8 | b[6 + 4 * i] << 16 |
			 (uint32_t)b[7 + 4 * i] << 24;
	return n;
}

/* Type, object count and object position of an 8-byte PD message at reg. */
static int request(struct port *p, uint16_t reg, int *type, int *nobj, int *pos)
{
	uint8_t b[8];
	int h;

	if (rd(p, reg, b, sizeof(b)))
		return -1;
	h = b[0] | b[1] << 8;
	*type = h & 0xf;
	*nobj = h >> 12 & 7;
	*pos = b[7] >> 4;
	return 0;
}

/* Ask for the highest fixed PDO up to MAX_MV if the contract is lower. */
static void upgrade(struct port *p, double t)
{
	uint32_t pdo[7], rdo;
	int type, nobj, cur, pos = 0, mv = 0, ma = 0, n, i, ctl, spos;

	if (p->tx >= MAX_TX || t - last_tx < TX_GAP)
		return;
	if (request(p, 0x06A0, &type, &nobj, &cur) || type != 2)
		return;
	n = caps(p, pdo);
	for (i = 0; i < n; i++) {
		int v = (pdo[i] >> 10 & 0x3ff) * 50;

		if (pdo[i] >> 30 == 0 && v > mv && v <= MAX_MV) {
			mv = v;
			pos = i + 1;
			ma = pdo[i] & 0x3ff;
		}
	}
	if (pos <= cur || mv <= 5000) {
		p->tx = MAX_TX; /* nothing better on offer; done for this attach */
		return;
	}
	if (request(p, 0x0080, &type, &nobj, &spos) || type != 2 || nobj != 1 || spos != pos) {
		/*
		 * The controller doesn't always stage the Request itself; write it
		 * in the form it uses: header 0x1002, USB communication and
		 * no-suspend set.
		 */
		uint8_t m[8] = { 0x02, 0x10, 0x00, 0x00 };

		rdo = (uint32_t)pos << 28 | 1 << 25 | 1 << 24 | ma << 10 | ma;
		for (i = 0; i < 4; i++)
			m[4 + i] = rdo >> (8 * i);
		for (i = 0; i < 8; i++)
			if (wr(p, 0x0080 + i, m[i]))
				return;
		if (request(p, 0x0080, &type, &nobj, &spos) || type != 2 || nobj != 1 ||
		    spos != pos) {
			printf("port %d: staging a Request for PDO %d failed\n", p->n, pos);
			p->tx = MAX_TX;
			return;
		}
	}
	ctl = rd1(p, 0x50);
	if (ctl < 0 || ctl & 0x40) /* transmitter busy */
		return;
	if (wr(p, 0x50, ctl | 0x40))
		return;
	p->tx++;
	last_tx = t;
	p->check_t = t + 2;
	printf("port %d: requested PDO %d (%d mV, %d mA), contract was PDO %d\n",
	       p->n, pos, mv, ma * 10, cur);
}

static void step(struct port *p, double t)
{
	uint32_t pdo[7];
	int a = rd1(p, 0x0E), s = rd1(p, 0x1C), type, nobj, pos;

	if (a < 0 || s < 0)
		return;
	if (a == 0)
		p->tx = 0;
	if (p->check_t && t >= p->check_t) {
		p->check_t = 0;
		if (!request(p, 0x06A0, &type, &nobj, &pos))
			printf("port %d: contract now PDO %d\n", p->n, pos);
	}
	if (t - p->cmd_t < SETTLE)
		return;
	/* A device we power that is removed leaves the provider switch on. */
	if (s & 0x01 && a != 0x01 && a != 0x11) {
		if (++p->gone >= GONE_POLLS) {
			command(p, 0x00, "device removed, VBUS off", a, s);
			p->gone = 0;
		}
		return;
	}
	p->gone = 0;
	if (a & 0x10 && !(a & 0x0e)) {
		/* A sink: VBUS only with no switch closed and no source in sight. */
		if (s == 0 && !caps(p, pdo))
			command(p, 0x09, "device attached, VBUS on", a, s);
	} else if (a & 0x0e && !(a & 0x10) && !(s & 0x01)) {
		/* A source, and we are not providing. */
		if (s != 0x0a) {
			if (caps(p, pdo))
				command(p, 0x12, "charger attached, input switch on", a, s);
		} else if (p->tx < MAX_TX) {
			upgrade(p, t);
		}
	}
}

int main(void)
{
	static const char *const controllers[] = { "a84000", "a9c000" };
	struct timespec poll = { 0, POLL_MS * 1000000L };
	struct port ports[2];
	char dev[32];
	int i;

	setvbuf(stdout, NULL, _IOLBF, 0);
	for (i = 0; i < 2; i++) {
		int bus = bus_of(controllers[i]);

		if (bus < 0) {
			fprintf(stderr, "i2c@%s not found\n", controllers[i]);
			return 1;
		}
		snprintf(dev, sizeof(dev), "/dev/i2c-%d", bus);
		ports[i] = (struct port){ .n = i, .fd = open(dev, O_RDWR), .cmd_t = -SETTLE };
		if (ports[i].fd < 0) {
			perror(dev);
			return 1;
		}
		printf("port %d: 0x0E=0x%02x 0x1C=0x%02x\n", i, rd1(&ports[i], 0x0E),
		       rd1(&ports[i], 0x1C));
	}
	for (;;) {
		double t = now();

		for (i = 0; i < 2; i++)
			step(&ports[i], t);
		nanosleep(&poll, NULL);
	}
}
