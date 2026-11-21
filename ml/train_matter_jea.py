"""
Sim-to-Real PyTorch training harness for `MatterJEA` (`LA-ML-ARCH-001` v1.0.0).

Trains `AcousticWaveEncoder` (`E_acous`) under the grounded multi-objective loss:
    L_total = L_SupCon + lambda_phys * (L_velocity + L_atten + L_bubble) + lambda_ood * L_OOD_reliability

Usage:
    python ml/train_matter_jea.py --epochs 15 --samples 12000 --batch-size 64 --out ml/checkpoints/e_acous.pt
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from torch.utils.data import DataLoader, Dataset

from models.wave_encoder import AcousticWaveEncoder
from synthetic_generator import SyntheticAScanGenerator


class SyntheticAcousticDataset(Dataset):
    """On-the-fly Sim-to-Real ultrasonic A-Scan dataset including Empty/Air-Gap OOD negative controls."""

    def __init__(
        self,
        size: int = 12_000,
        total_samples: int = 8800,
        ood_fraction: float = 0.12,
        seed: int = 42,
    ):
        self.size = size
        self.total_samples = total_samples
        self.ood_fraction = ood_fraction
        self.seed = seed
        self.gen = SyntheticAScanGenerator()
        self.liquids: List[str] = list(self.gen.liquid_db.keys())

    def __len__(self) -> int:
        return self.size

    def __getitem__(self, idx: int) -> Tuple[torch.Tensor, int, Dict[str, np.float32]]:
        rng = np.random.default_rng(self.seed + idx)
        t_wall = float(rng.uniform(0.0018, 0.0068))
        snr = float(rng.uniform(16.0, 42.0))

        # Inject explicit Empty Cup / Air-Gap OOD negatives (label = -1)
        if rng.random() < self.ood_fraction:
            trace, meta = self.gen.generate_ood_empty_trace(
                wall_thickness_m=t_wall,
                snr_db=snr,
                total_samples=self.total_samples,
                rng=rng,
            )
            return torch.from_numpy(trace), -1, meta

        label_idx = int(rng.integers(0, len(self.liquids)))
        liq_name = self.liquids[label_idx]
        # Keep diameter inside the 220 us window even for Ethanol (1210 m/s) when total_samples == 8800
        max_d = 0.062 if (liq_name == "ISOPROPYL_ALC" and self.total_samples <= 8800) else 0.072
        d = float(rng.uniform(0.045, max_d))
        temp = float(rng.uniform(10.0, 38.0))
        bubble = bool(rng.random() > 0.78) if liq_name != "SELTZER_CARBONATED" else True

        trace, meta = self.gen.generate_single_trace(
            liquid_name=liq_name,
            container_diameter_m=d,
            wall_thickness_m=t_wall,
            temp_c=temp,
            snr_db=snr,
            inject_bubble=bubble,
            total_samples=self.total_samples,
            rng=rng,
        )
        return torch.from_numpy(trace), label_idx, meta


def supervised_contrastive_loss(
    embeddings: torch.Tensor,
    labels: torch.Tensor,
    temperature: float = 0.07,
) -> torch.Tensor:
    """Supervised contrastive loss over in-distribution samples (`labels >= 0`)."""
    valid_mask = labels >= 0
    if valid_mask.sum() < 2:
        return embeddings.new_tensor(0.0)

    emb = embeddings[valid_mask]
    lbl = labels[valid_mask].contiguous().view(-1, 1)
    n = emb.shape[0]

    sim = torch.matmul(emb, emb.T) / temperature
    pos_mask = torch.eq(lbl, lbl.T).float()
    logits_mask = 1.0 - torch.eye(n, device=emb.device, dtype=torch.float32)
    pos_mask = pos_mask * logits_mask

    logits_max, _ = torch.max(sim, dim=1, keepdim=True)
    logits = sim - logits_max.detach()

    exp_logits = torch.exp(logits) * logits_mask
    log_prob = logits - torch.log(exp_logits.sum(dim=1, keepdim=True) + 1e-7)

    pos_counts = pos_mask.sum(dim=1)
    has_pos = pos_counts > 0
    if not torch.any(has_pos):
        return embeddings.new_tensor(0.0)

    mean_log_prob_pos = (pos_mask[has_pos] * log_prob[has_pos]).sum(dim=1) / pos_counts[has_pos]
    return -mean_log_prob_pos.mean()


def train_epoch(
    model: AcousticWaveEncoder,
    loader: DataLoader,
    optimizer: torch.optim.Optimizer,
    device: torch.device,
) -> Dict[str, float]:
    model.train()
    huber = nn.HuberLoss(delta=10.0)
    bce_logits = nn.BCEWithLogitsLoss()
    bce_prob = nn.BCELoss()

    totals = {"loss": 0.0, "supcon": 0.0, "vel": 0.0, "atten": 0.0, "bubble": 0.0, "ood": 0.0}
    steps = 0

    for batch_x, batch_y, meta in loader:
        batch_x = batch_x.to(device, dtype=torch.float32)
        batch_y = batch_y.to(device, dtype=torch.long)

        in_dist = batch_y >= 0
        gt_c20 = meta["c_20"].to(device, dtype=torch.float32).unsqueeze(1)
        gt_atten = meta["attenuation"].to(device, dtype=torch.float32).unsqueeze(1)
        gt_bubble = meta["has_inverted_bubble"].to(device, dtype=torch.float32).unsqueeze(1)
        gt_reliability = (1.0 - meta["is_ood"].to(device, dtype=torch.float32)).unsqueeze(1)

        optimizer.zero_grad()
        z_a, w_a, phys = model(batch_x)

        l_supcon = supervised_contrastive_loss(z_a, batch_y)
        if torch.any(in_dist):
            l_vel = huber(phys["c_20"][in_dist], gt_c20[in_dist]) / 50.0
            l_atten = F.mse_loss(phys["attenuation"][in_dist], gt_atten[in_dist])
            l_bubble = bce_logits(phys["bubble_logit"][in_dist], gt_bubble[in_dist])
        else:
            zero = batch_x.new_tensor(0.0)
            l_vel, l_atten, l_bubble = zero, zero, zero

        # Reliability head learns w_a -> 1 for valid liquid echoes and w_a -> 0 for empty/air-gap OOD frames
        l_ood = bce_prob(w_a.clamp(1e-5, 1.0 - 1e-5), gt_reliability)

        loss = l_supcon + 1.0 * (l_vel + l_atten + 0.35 * l_bubble) + 0.40 * l_ood
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), max_norm=2.0)
        optimizer.step()

        totals["loss"] += float(loss.item())
        totals["supcon"] += float(l_supcon.item())
        totals["vel"] += float(l_vel.item())
        totals["atten"] += float(l_atten.item())
        totals["bubble"] += float(l_bubble.item())
        totals["ood"] += float(l_ood.item())
        steps += 1

    return {k: v / max(1, steps) for k, v in totals.items()}


@torch.no_grad()
def compute_class_prototypes(
    model: AcousticWaveEncoder,
    dataset: SyntheticAcousticDataset,
    device: torch.device,
    samples_per_class: int = 128,
) -> Dict[str, List[float]]:
    """Computes L2-normalized 128-D reference centroids for `MatterPerceptionEngine` prototype bank."""
    model.eval()
    prototypes: Dict[str, List[float]] = {}
    rng = np.random.default_rng(9999)

    for liq_name in dataset.liquids:
        batch = []
        for _ in range(samples_per_class):
            d = float(rng.uniform(0.048, 0.062))
            trace, _ = dataset.gen.generate_single_trace(
                liquid_name=liq_name,
                container_diameter_m=d,
                wall_thickness_m=float(rng.uniform(0.0020, 0.0060)),
                temp_c=float(rng.uniform(15.0, 28.0)),
                snr_db=float(rng.uniform(24.0, 38.0)),
                total_samples=dataset.total_samples,
                rng=rng,
            )
            batch.append(trace)
        x = torch.from_numpy(np.stack(batch, axis=0)).to(device, dtype=torch.float32)
        z_a, _, _ = model(x)
        centroid = F.normalize(z_a.mean(dim=0, keepdim=True), p=2, dim=-1).squeeze(0)
        prototypes[liq_name] = [round(float(v), 6) for v in centroid.cpu().tolist()]

    return prototypes


def main() -> None:
    parser = argparse.ArgumentParser(description="Train MatterJEA AcousticWaveEncoder (Sim-to-Real)")
    parser.add_argument("--epochs", type=int, default=15)
    parser.add_argument("--samples", type=int, default=12_000)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--out", type=str, default="ml/checkpoints/e_acous.pt")
    args = parser.parse_args()

    if torch.cuda.is_available():
        device = torch.device("cuda")
    elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        device = torch.device("mps")
    else:
        device = torch.device("cpu")

    print(f"[MatterJEA] Training E_acous on {device} ({args.samples} synthetic A-Scans, {args.epochs} epochs)")
    dataset = SyntheticAcousticDataset(size=args.samples)
    loader = DataLoader(dataset, batch_size=args.batch_size, shuffle=True, drop_last=True)

    model = AcousticWaveEncoder(latent_dim=128).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer, T_max=max(1, args.epochs))

    for epoch in range(1, args.epochs + 1):
        metrics = train_epoch(model, loader, optimizer, device)
        scheduler.step()
        print(
            f"Epoch {epoch:02d}/{args.epochs:02d} | "
            f"loss={metrics['loss']:.4f} | supcon={metrics['supcon']:.4f} | "
            f"vel={metrics['vel']:.4f} | atten={metrics['atten']:.4f} | "
            f"bubble={metrics['bubble']:.4f} | ood={metrics['ood']:.4f}"
        )

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(model.state_dict(), out_path)
    print(f"[MatterJEA] Saved weights -> {out_path}")

    proto_path = out_path.with_suffix(".prototypes.json")
    prototypes = compute_class_prototypes(model, dataset, device)
    proto_path.write_text(json.dumps(prototypes, indent=2), encoding="utf-8")
    print(f"[MatterJEA] Saved 128-D prototype bank -> {proto_path}")


if __name__ == "__main__":
    main()
