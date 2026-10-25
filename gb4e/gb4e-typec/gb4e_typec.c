// SPDX-License-Identifier: GPL-2.0
/*
 * USB-C orientation and mode for the Samsung Galaxy Book4 Edge 14.
 *
 * The SuperSpeed lanes of each USB-C port go through a Parade PS8830 retimer
 * to the QMP combo PHY. The ps883x driver only lets them through once a Type-C
 * port driver sets the plug orientation and the USB mode, and this machine has
 * none: its Samsung S2MM006 PD controllers have no kernel driver, and
 * pmic_glink's UCSI never gets a port from the ADSP. This module takes each
 * pmic-glink connector's orientation switch and retimer and lets userspace
 * set them:
 *
 *   echo normal|reverse|none > /sys/devices/platform/gb4e-typec/port0
 *
 * normal and reverse also put the retimer in USB mode; none puts it in safe
 * mode, which holds it in reset. The usbc service writes these from the PD
 * controllers' state.
 */
#include <linux/device.h>
#include <linux/err.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/string.h>
#include <linux/usb/typec.h>
#include <linux/usb/typec_altmode.h>
#include <linux/usb/typec_mux.h>
#include <linux/usb/typec_retimer.h>

#define GB4E_PORTS 2

struct gb4e_port {
	struct typec_switch *sw;
	struct typec_retimer *retimer;
	enum typec_orientation orientation;
};

struct gb4e_typec {
	struct mutex lock;
	struct gb4e_port port[GB4E_PORTS];
};

static const char *const orientation_names[] = {
	[TYPEC_ORIENTATION_NONE] = "none",
	[TYPEC_ORIENTATION_NORMAL] = "normal",
	[TYPEC_ORIENTATION_REVERSE] = "reverse",
};

static struct platform_device *gb4e_pdev;

static int gb4e_set(struct gb4e_port *p, enum typec_orientation orientation)
{
	struct typec_retimer_state state = {
		.mode = orientation == TYPEC_ORIENTATION_NONE ? TYPEC_STATE_SAFE : TYPEC_STATE_USB,
	};
	int ret;

	/* The retimer applies the orientation with the mode that follows. */
	ret = typec_switch_set(p->sw, orientation);
	if (!ret)
		ret = typec_retimer_set(p->retimer, &state);
	if (!ret)
		p->orientation = orientation;
	return ret;
}

static ssize_t port_show(struct device *dev, int n, char *buf)
{
	struct gb4e_typec *t = dev_get_drvdata(dev);

	return sysfs_emit(buf, "%s\n", orientation_names[t->port[n].orientation]);
}

static ssize_t port_store(struct device *dev, int n, const char *buf, size_t count)
{
	struct gb4e_typec *t = dev_get_drvdata(dev);
	int orientation = sysfs_match_string(orientation_names, buf);
	int ret;

	if (orientation < 0)
		return orientation;
	mutex_lock(&t->lock);
	ret = gb4e_set(&t->port[n], orientation);
	mutex_unlock(&t->lock);
	return ret ?: count;
}

static ssize_t port0_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return port_show(dev, 0, buf);
}

static ssize_t port0_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t count)
{
	return port_store(dev, 0, buf, count);
}

static ssize_t port1_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	return port_show(dev, 1, buf);
}

static ssize_t port1_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t count)
{
	return port_store(dev, 1, buf, count);
}

static DEVICE_ATTR_RW(port0);
static DEVICE_ATTR_RW(port1);

static struct attribute *gb4e_attrs[] = {
	&dev_attr_port0.attr,
	&dev_attr_port1.attr,
	NULL
};
ATTRIBUTE_GROUPS(gb4e);

static void gb4e_put(void *data)
{
	struct gb4e_port *p = data;

	typec_retimer_put(p->retimer);
	typec_switch_put(p->sw);
}

static int gb4e_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct gb4e_typec *t;
	int i, ret;

	t = devm_kzalloc(dev, sizeof(*t), GFP_KERNEL);
	if (!t)
		return -ENOMEM;
	mutex_init(&t->lock);

	for (i = 0; i < GB4E_PORTS; i++) {
		struct gb4e_port *p = &t->port[i];
		char path[32];
		struct device_node *np;

		snprintf(path, sizeof(path), "/pmic-glink/connector@%d", i);
		np = of_find_node_by_path(path);
		if (!np)
			return dev_err_probe(dev, -ENODEV, "%s not found\n", path);
		p->sw = fwnode_typec_switch_get(of_fwnode_handle(np));
		p->retimer = fwnode_typec_retimer_get(of_fwnode_handle(np));
		of_node_put(np);
		if (IS_ERR_OR_NULL(p->sw) || IS_ERR_OR_NULL(p->retimer)) {
			ret = IS_ERR(p->retimer) ? PTR_ERR(p->retimer) :
			      IS_ERR(p->sw) ? PTR_ERR(p->sw) : -ENODEV;
			if (!IS_ERR_OR_NULL(p->retimer))
				typec_retimer_put(p->retimer);
			if (!IS_ERR_OR_NULL(p->sw))
				typec_switch_put(p->sw);
			return dev_err_probe(dev, ret, "port %d: no retimer or switch\n", i);
		}
		ret = devm_add_action_or_reset(dev, gb4e_put, p);
		if (ret)
			return ret;
	}
	platform_set_drvdata(pdev, t);
	dev_info(dev, "USB-C retimers ready\n");
	return 0;
}

static struct platform_driver gb4e_driver = {
	.probe = gb4e_probe,
	.driver = {
		.name = "gb4e-typec",
		.dev_groups = gb4e_groups,
	},
};

static int __init gb4e_init(void)
{
	int ret;

	if (!of_machine_is_compatible("samsung,galaxy-book4-edge-14"))
		return -ENODEV;
	ret = platform_driver_register(&gb4e_driver);
	if (ret)
		return ret;
	gb4e_pdev = platform_device_register_simple("gb4e-typec", PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(gb4e_pdev)) {
		platform_driver_unregister(&gb4e_driver);
		return PTR_ERR(gb4e_pdev);
	}
	return 0;
}

static void __exit gb4e_exit(void)
{
	platform_device_unregister(gb4e_pdev);
	platform_driver_unregister(&gb4e_driver);
}

module_init(gb4e_init);
module_exit(gb4e_exit);
MODULE_DESCRIPTION("USB-C orientation and mode for the Samsung Galaxy Book4 Edge 14");
MODULE_LICENSE("GPL");
