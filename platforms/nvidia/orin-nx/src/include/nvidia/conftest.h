/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Fallback <nvidia/conftest.h> for NVIDIA L4T R39+ (JetPack 7.2+), where
 * /usr/src/nvidia/nvidia-public/include/media/camera_common.h includes
 * <nvidia/conftest.h> and depends on NV_TEGRA_PMC_IO_PAD_POWER_ENABLE_PRESENT
 * to match the struct camera_common_data layout compiled into tegra-camera.ko.
 */
#ifndef __RS300_NVIDIA_CONFTEST_H__
#define __RS300_NVIDIA_CONFTEST_H__

#include <linux/version.h>

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 5, 0)
#ifndef NV_V4L2_ASYNC_CONNECTION_STRUCT_PRESENT
#define NV_V4L2_ASYNC_CONNECTION_STRUCT_PRESENT 1
#endif
#endif

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 8, 0)
#ifndef NV_TEGRA_PMC_IO_PAD_POWER_ENABLE_PRESENT
#define NV_TEGRA_PMC_IO_PAD_POWER_ENABLE_PRESENT 1
#endif
#endif

#endif /* __RS300_NVIDIA_CONFTEST_H__ */
