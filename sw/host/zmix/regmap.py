# SPDX-License-Identifier: MIT
"""Runtime model for the generated register definitions.

The generated modules under `zmix.regs` are pure data; this module gives that
data behaviour -- field packing and unpacking, pretty-printing, and lookup by
name -- so a driver can say `adc.ctrl.set(ENABLE=1)` instead of open-coding
shifts and masks at every call site.
"""

from __future__ import annotations

import dataclasses


@dataclasses.dataclass(frozen=True)
class Field:
    name: str
    hi: int
    lo: int
    description: str = ""

    @property
    def width(self) -> int:
        return self.hi - self.lo + 1

    @property
    def mask(self) -> int:
        return ((1 << self.width) - 1) << self.lo

    def extract(self, word: int) -> int:
        """Pull this field's value out of a full register word."""
        return (word & self.mask) >> self.lo

    def insert(self, word: int, value: int) -> int:
        """Return `word` with this field replaced by `value`."""
        if value < 0 or value >= (1 << self.width):
            raise ValueError(
                f"{self.name}: value {value} does not fit in {self.width} bit(s)"
            )
        return (word & ~self.mask) | (value << self.lo)


@dataclasses.dataclass(frozen=True)
class Register:
    name: str
    offset: int
    access: str
    reset: int = 0
    description: str = ""
    fields: list[Field] = dataclasses.field(default_factory=list)

    @property
    def writable(self) -> bool:
        return self.access == "rw"

    def field(self, name: str) -> Field:
        for candidate in self.fields:
            if candidate.name == name:
                return candidate
        raise KeyError(f"{self.name} has no field {name!r}")

    def pack(self, base: int = 0, **values: int) -> int:
        """Build a register word from field values, starting from `base`."""
        word = base
        for name, value in values.items():
            word = self.field(name).insert(word, int(value))
        return word

    def unpack(self, word: int) -> dict[str, int]:
        """Split a register word into its named fields."""
        return {f.name: f.extract(word) for f in self.fields}

    def describe(self, word: int) -> str:
        """One-line human-readable decode, for logs and error messages."""
        if not self.fields:
            return f"{self.name}=0x{word:08X}"
        parts = " ".join(f"{n}={v}" for n, v in self.unpack(word).items())
        return f"{self.name}=0x{word:08X} [{parts}]"


@dataclasses.dataclass(frozen=True)
class Block:
    name: str
    description: str
    registers: list[Register]

    def register(self, name: str) -> Register:
        for candidate in self.registers:
            if candidate.name == name:
                return candidate
        raise KeyError(f"block {self.name} has no register {name!r}")

    def __iter__(self):
        return iter(self.registers)


@dataclasses.dataclass(frozen=True)
class Instance:
    name: str
    block: str
    base: int
    description: str = ""
