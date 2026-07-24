#include <linux/module.h>
#define INCLUDE_VERMAGIC
#include <linux/build-salt.h>
#include <linux/elfnote-lto.h>
#include <linux/vermagic.h>
#include <linux/compiler.h>

BUILD_SALT;
BUILD_LTO_INFO;

MODULE_INFO(vermagic, VERMAGIC_STRING);
MODULE_INFO(name, KBUILD_MODNAME);

__visible struct module __this_module
__section(".gnu.linkonce.this_module") = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};

#ifdef CONFIG_RETPOLINE
MODULE_INFO(retpoline, "Y");
#endif

static const struct modversion_info ____versions[]
__used __section("__versions") = {
	{ 0x24d702c7, "module_layout" },
	{ 0x10e00301, "tegracam_device_register" },
	{ 0xcb6838a0, "tegracam_set_privdata" },
	{ 0x9dd12f30, "__dev_fwnode" },
	{ 0xeb233a45, "__kmalloc" },
	{ 0xf9a482f9, "msleep" },
	{ 0x1fdc7df2, "_mcount" },
	{ 0x48c78bcd, "param_ops_int" },
	{ 0xab699cb4, "fwnode_handle_put" },
	{ 0x8677495a, "i2c_del_driver" },
	{ 0x1e343eb0, "i2c_transfer" },
	{ 0xfaa82cd8, "v4l2_ctrl_handler_free" },
	{ 0x12a4e128, "__arch_copy_from_user" },
	{ 0x38b81527, "v4l2_ctrl_new_std" },
	{ 0xe3787975, "gpio_to_desc" },
	{ 0xe96b75bf, "v4l2_fwnode_endpoint_alloc_parse" },
	{ 0xec881cfd, "tegracam_get_privdata" },
	{ 0x3213f038, "mutex_unlock" },
	{ 0x3b9aa5b0, "v4l2_ctrl_subdev_log_status" },
	{ 0xd811fe08, "sensor_common_parse_num_modes" },
	{ 0xd6b6915b, "tegracam_device_unregister" },
	{ 0xdcd3d5c7, "devm_regulator_bulk_get" },
	{ 0xbed1c28f, "regulator_bulk_enable" },
	{ 0x451e457e, "camera_common_find_datafmt" },
	{ 0xe2822320, "__v4l2_find_nearest_size" },
	{ 0x95df6106, "_dev_warn" },
	{ 0xdcb764ad, "memset" },
	{ 0x6134f2d3, "tegracam_v4l2subdev_register" },
	{ 0x4b0a3f52, "gic_nonsecure_priorities" },
	{ 0xaa9bfae5, "v4l2_ctrl_subdev_subscribe_event" },
	{ 0xcefb0c9f, "__mutex_init" },
	{ 0xa630077c, "__v4l2_ctrl_s_ctrl_int64" },
	{ 0x449ad0a7, "memcmp" },
	{ 0x853fa3d5, "of_property_read_string" },
	{ 0x9166fada, "strncpy" },
	{ 0x4dfa8d4b, "mutex_lock" },
	{ 0x519831c9, "v4l2_ctrl_new_custom" },
	{ 0xc42c119c, "_dev_err" },
	{ 0xef602dd6, "devm_gpio_request_one" },
	{ 0xacd3a81f, "i2c_register_driver" },
	{ 0xfba90312, "v4l2_ctrl_new_int_menu" },
	{ 0x845d17cc, "_dev_info" },
	{ 0x63cccd51, "regulator_bulk_disable" },
	{ 0x6cbbfc54, "__arch_copy_to_user" },
	{ 0x3ea1b6e4, "__stack_chk_fail" },
	{ 0x1e49e99f, "cpu_hwcaps" },
	{ 0x53b5f2e8, "of_get_named_gpio_flags" },
	{ 0x31909811, "cpu_hwcap_keys" },
	{ 0x291e78b1, "v4l2_event_subdev_unsubscribe" },
	{ 0x94047edd, "devm_gpiod_get_optional" },
	{ 0x37a0cba, "kfree" },
	{ 0x4829a47e, "memcpy" },
	{ 0xa3f09ec5, "fwnode_graph_get_next_endpoint" },
	{ 0x422ffa48, "v4l2_fwnode_endpoint_free" },
	{ 0xe4b6e5c5, "v4l2_ctrl_handler_init_class" },
	{ 0x9e9c0323, "gpiod_set_value_cansleep" },
	{ 0x5e913504, "v4l2_ctrl_add_handler" },
	{ 0xf22a7461, "tegracam_v4l2subdev_unregister" },
	{ 0xa35e7c1e, "devm_kmalloc" },
	{ 0x14b89635, "arm64_const_caps_ready" },
	{ 0x88db9f48, "__check_object_size" },
	{ 0x8e328a95, "v4l2_i2c_subdev_init" },
};

MODULE_INFO(depends, "tegra-camera,videodev,v4l2-fwnode");

MODULE_ALIAS("of:N*T*Cmini2,rs300");
MODULE_ALIAS("of:N*T*Cmini2,rs300C*");
MODULE_ALIAS("of:N*T*Cinfisense,rs300");
MODULE_ALIAS("of:N*T*Cinfisense,rs300C*");
MODULE_ALIAS("i2c:rs300");
