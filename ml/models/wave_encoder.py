"""
Multi-Scale 1D Dilated ResNet (`E_acous`) implementing Section 2.1 of `LA-ML-ARCH-001`.
Maps dual-channel ultrasonic A-Scans `[B, 2, L]` (signed RF + Hilbert envelope) onto S^127.
"""

from __future__ import annotations

from typing import Dict, Tuple
import torch
import torch.nn as nn
import torch.nn.functional as F


class DilatedResidualBlock1D(nn.Module):
    def __init__(self, channels: int, dilation: int):
        super().__init__()
        self.conv1 = nn.Conv1d(
            channels,
            channels,
            kernel_size=5,
            padding=2 * dilation,
            dilation=dilation,
        )
        self.bn1 = nn.BatchNorm1d(channels)
        self.conv2 = nn.Conv1d(
            channels,
            channels,
            kernel_size=5,
            padding=2 * dilation,
            dilation=dilation,
        )
        self.bn2 = nn.BatchNorm1d(channels)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        residual = x
        out = F.gelu(self.bn1(self.conv1(x)))
        out = self.bn2(self.conv2(out))
        return F.gelu(out + residual)


class AcousticWaveEncoder(nn.Module):
    """E_acous: 1D Multi-Scale Dilated ResNet mapping [B, 2, L] -> z_a in S^127."""

    def __init__(self, latent_dim: int = 128):
        super().__init__()
        # Stem: subsamples 8,800 samples by 4x -> 2,200 while preserving RF phase polarity
        self.stem = nn.Sequential(
            nn.Conv1d(2, 32, kernel_size=15, stride=4, padding=7),
            nn.BatchNorm1d(32),
            nn.GELU(),
        )

        self.stage1 = nn.Sequential(
            DilatedResidualBlock1D(32, dilation=1),
            DilatedResidualBlock1D(32, dilation=2),
        )
        self.down1 = nn.Conv1d(32, 64, kernel_size=3, stride=2, padding=1)

        self.stage2 = nn.Sequential(
            DilatedResidualBlock1D(64, dilation=2),
            DilatedResidualBlock1D(64, dilation=4),
        )
        self.down2 = nn.Conv1d(64, 128, kernel_size=3, stride=2, padding=1)

        self.stage3 = nn.Sequential(
            DilatedResidualBlock1D(128, dilation=4),
            DilatedResidualBlock1D(128, dilation=8),
        )
        self.stage4 = nn.Sequential(
            DilatedResidualBlock1D(128, dilation=8),
            DilatedResidualBlock1D(128, dilation=16),
        )

        self.pool = nn.AdaptiveAvgPool1d(1)
        self.proj = nn.Linear(128, latent_dim)

        # Uncertainty / Reliability scoring head: w_a in [0, 1]
        self.reliability_head = nn.Sequential(
            nn.Linear(128, 32),
            nn.GELU(),
            nn.Linear(32, 1),
            nn.Sigmoid(),
        )

        # Physics-consistency auxiliary heads
        self.head_velocity = nn.Linear(128, 1)     # Predicts c_20C (m/s)
        self.head_attenuation = nn.Linear(128, 1)  # Predicts A2 / A1 ratio
        self.head_polarity = nn.Linear(128, 1)     # Predicts inverted bubble logit

    def forward(
        self, x: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor, Dict[str, torch.Tensor]]:
        h = self.stem(x)
        h = self.down1(self.stage1(h))
        h = self.down2(self.stage2(h))
        h = self.stage4(self.stage3(h))
        feat = self.pool(h).squeeze(-1)

        z_a = F.normalize(self.proj(feat), p=2, dim=-1)
        w_a = self.reliability_head(feat)

        phys_preds = {
            "c_20": self.head_velocity(feat),
            "attenuation": self.head_attenuation(feat),
            "bubble_logit": self.head_polarity(feat),
        }
        return z_a, w_a, phys_preds


class CoreMLAcousticExportWrapper(nn.Module):
    """Flat-tuple wrapper around `AcousticWaveEncoder` required for strict `torch.jit.trace` & `coremltools` export."""

    def __init__(self, encoder: AcousticWaveEncoder):
        super().__init__()
        self.encoder = encoder

    def forward(
        self, x: torch.Tensor
    ) -> Tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        z_a, w_a, phys = self.encoder(x)
        return z_a, w_a, phys["c_20"], phys["attenuation"], phys["bubble_logit"]
