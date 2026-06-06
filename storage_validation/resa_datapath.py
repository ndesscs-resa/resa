#!/usr/bin/env python3
"""Datapath layout and timing record for the PM9A3/CSD integration model."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path


@dataclass
class DatabaseConfig:
    n_vectors: int = 100_000_000
    embedding_dim: int = 768
    vectors_per_group: int = 4096

    @property
    def n_groups(self) -> int:
        return math.ceil(self.n_vectors / self.vectors_per_group)

    @property
    def ctxts_per_group(self) -> int:
        return self.embedding_dim


@dataclass
class HEConfig:
    ring_dim_N: int = 4096
    coeff_bits: int = 51
    storage_mode: str = "seeded_a"
    seed_bytes_per_group: int = 32

    @property
    def coeffs_per_ctxt(self) -> int:
        return 2 * self.ring_dim_N

    @property
    def stored_coeffs_per_ctxt(self) -> int:
        if self.storage_mode != "seeded_a":
            raise ValueError(f"unsupported storage_mode: {self.storage_mode}")
        return self.ring_dim_N

    @property
    def stored_bits_per_ctxt(self) -> int:
        return self.stored_coeffs_per_ctxt * self.coeff_bits


@dataclass
class StorageLayoutConfig:
    channel_count: int = 16
    page_size_bytes: int = 16384
    layout: str = "coefficient-striped continuous 51-bit packing"


@dataclass
class ComputeConfig:
    datapath_mode: str = "seeded_a_split"
    b_pes: int = 8
    a_pes: int = 8
    total_pes: int = 16
    axis_width_bits: int = 1024
    clock_mhz: int = 500

    @property
    def clock_us(self) -> float:
        return 1.0 / self.clock_mhz


@dataclass
class WritebackConfig:
    result_bytes: int = 65536
    dma_bw_gbps: float = 10.0
    pack_time_us: float = 0.5
    path: str = "resa_axis_stream_to_ssd_controller_dma_to_host_memory"


@dataclass
class DatapathConfig:
    db: DatabaseConfig
    he: HEConfig
    storage_layout: StorageLayoutConfig
    compute: ComputeConfig
    writeback: WritebackConfig

    @classmethod
    def from_json(cls, path: str | Path) -> "DatapathConfig":
        data = json.loads(Path(path).read_text())
        schema_version = data.get("schema_version")
        if schema_version != 1:
            raise ValueError(f"unsupported datapath profile schema_version: {schema_version!r}")
        config = cls(
            db=DatabaseConfig(**data.get("database", {})),
            he=HEConfig(**data.get("he_params", {})),
            storage_layout=StorageLayoutConfig(**data.get("storage_layout", {})),
            compute=ComputeConfig(**data.get("compute", {})),
            writeback=WritebackConfig(**data.get("writeback", {})),
        )
        config.validate()
        return config

    def validate(self) -> None:
        if self.db.n_vectors <= 0:
            raise ValueError("database.n_vectors must be positive")
        if self.db.embedding_dim <= 0:
            raise ValueError("database.embedding_dim must be positive")
        if self.db.vectors_per_group <= 0:
            raise ValueError("database.vectors_per_group must be positive")
        if self.he.ring_dim_N <= 0 or self.he.coeff_bits <= 0:
            raise ValueError("he_params ring_dim_N and coeff_bits must be positive")
        if self.he.storage_mode != "seeded_a":
            raise ValueError(f"unsupported storage_mode: {self.he.storage_mode}")
        if self.storage_layout.channel_count <= 0:
            raise ValueError("storage_layout.channel_count must be positive")
        if self.storage_layout.page_size_bytes <= 0:
            raise ValueError("storage_layout.page_size_bytes must be positive")
        if self.compute.datapath_mode != "seeded_a_split":
            raise ValueError(f"unsupported datapath_mode: {self.compute.datapath_mode}")
        if min(self.compute.b_pes, self.compute.a_pes, self.compute.total_pes) <= 0:
            raise ValueError("compute PE counts must be positive")
        if self.compute.axis_width_bits <= 0 or self.compute.clock_mhz <= 0:
            raise ValueError("compute axis_width_bits and clock_mhz must be positive")
        if self.writeback.result_bytes <= 0:
            raise ValueError("writeback.result_bytes must be positive")
        if self.writeback.dma_bw_gbps <= 0:
            raise ValueError("writeback.dma_bw_gbps must be positive")


@dataclass
class DataLayout:
    config: DatapathConfig

    @property
    def stored_payload_bits_per_group(self) -> int:
        return self.config.db.ctxts_per_group * self.config.he.stored_bits_per_ctxt

    @property
    def seed_bits_per_group(self) -> int:
        return self.config.he.seed_bytes_per_group * 8

    @property
    def bits_per_group(self) -> int:
        return self.stored_payload_bits_per_group + self.seed_bits_per_group

    @property
    def bits_per_channel_per_group(self) -> int:
        return math.ceil(self.bits_per_group / self.config.storage_layout.channel_count)

    @property
    def pages_per_channel_per_group(self) -> int:
        page_bits = self.config.storage_layout.page_size_bytes * 8
        return math.ceil(self.bits_per_channel_per_group / page_bits)

    @property
    def total_db_bytes(self) -> int:
        return (
            self.config.db.n_groups
            * self.config.storage_layout.channel_count
            * self.pages_per_channel_per_group
            * self.config.storage_layout.page_size_bytes
        )

    @property
    def total_db_gb_decimal(self) -> float:
        return self.total_db_bytes / 1e9


@dataclass
class GroupComputeResult:
    ctxts_processed: int
    total_cycles: int
    total_time_us: float
    total_time_ms: float
    cycles_per_ctxt: int


@dataclass
class WritebackTiming:
    reduce_cycles: int
    reduce_time_us: float
    pack_time_us: float
    dma_time_us: float
    total_time_us: float


def cycles_per_ctxt(config: DatapathConfig) -> int:
    if config.compute.datapath_mode != "seeded_a_split":
        raise ValueError(f"unsupported datapath_mode: {config.compute.datapath_mode}")
    b_cycles = math.ceil(config.he.ring_dim_N / config.compute.b_pes)
    a_cycles = math.ceil(config.he.ring_dim_N / config.compute.a_pes)
    return max(b_cycles, a_cycles)


def compute_group_timing(config: DatapathConfig) -> GroupComputeResult:
    cycles = cycles_per_ctxt(config)
    total_cycles = config.db.ctxts_per_group * cycles
    total_time_us = total_cycles * config.compute.clock_us
    return GroupComputeResult(
        ctxts_processed=config.db.ctxts_per_group,
        total_cycles=total_cycles,
        total_time_us=total_time_us,
        total_time_ms=total_time_us / 1000.0,
        cycles_per_ctxt=cycles,
    )


def writeback_timing(config: DatapathConfig) -> WritebackTiming:
    reduce_cycles = math.ceil(config.he.coeffs_per_ctxt / config.compute.total_pes)
    reduce_time_us = reduce_cycles * config.compute.clock_us
    dma_time_us = config.writeback.result_bytes / (config.writeback.dma_bw_gbps * 1e9 / 1e6)
    total_time_us = reduce_time_us + config.writeback.pack_time_us + dma_time_us
    return WritebackTiming(
        reduce_cycles=reduce_cycles,
        reduce_time_us=reduce_time_us,
        pack_time_us=config.writeback.pack_time_us,
        dma_time_us=dma_time_us,
        total_time_us=total_time_us,
    )
