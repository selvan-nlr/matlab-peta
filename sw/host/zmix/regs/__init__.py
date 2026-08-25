# SPDX-License-Identifier: MIT
"""Generated register definitions. Do not edit the modules in this package by hand."""

from . import system
from . import adc_ad7476
from . import dac_spi
from . import oled_ctrl
from . import sysid

BLOCKS = {
    'adc_ad7476': adc_ad7476.BLOCK,
    'dac_spi': dac_spi.BLOCK,
    'oled_ctrl': oled_ctrl.BLOCK,
    'sysid': sysid.BLOCK,
}

__all__ = ["BLOCKS", "system", 'adc_ad7476', 'dac_spi', 'oled_ctrl', 'sysid']
