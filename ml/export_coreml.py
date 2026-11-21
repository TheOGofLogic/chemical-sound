"""
CoreML FP16 export pipeline for `MatterJEA` (`AcousticWaveEncoder` -> Apple Neural Engine `.mlpackage`).

Usage:
    python ml/export_coreml.py --weights ml/checkpoints/e_acous.pt --out ml/checkpoints/MatterAcousticEncoder.mlpackage
"""

from __future__ import annotations

import argparse
from typing import Optional

import coremltools as ct
import torch

from models.wave_encoder import AcousticWaveEncoder, CoreMLAcousticExportWrapper


def export_encoder_to_coreml(
    weights_path: Optional[str] = None,
    output_path: str = "MatterAcousticEncoder.mlpackage",
    sample_length: int = 8800,
) -> None:
    device = torch.device("cpu")
    encoder = AcousticWaveEncoder(latent_dim=128)
    if weights_path:
        state_dict = torch.load(weights_path, map_location=device, weights_only=True)
        encoder.load_state_dict(state_dict)
    encoder.eval()

    export_module = CoreMLAcousticExportWrapper(encoder).eval()

    # Trace flat-tuple output contract: [1, 2, L] -> (z_a, w_a, pred_c20, pred_atten, pred_bubble_logit)
    dummy_input = torch.randn(1, 2, sample_length, dtype=torch.float32)
    with torch.no_grad():
        traced_model = torch.jit.trace(export_module, dummy_input)

    input_shape = ct.TensorType(name="acoustic_stream", shape=(1, 2, sample_length))

    mlmodel = ct.convert(
        traced_model,
        inputs=[input_shape],
        outputs=[
            ct.TensorType(name="z_a"),
            ct.TensorType(name="w_a"),
            ct.TensorType(name="pred_c20"),
            ct.TensorType(name="pred_atten"),
            ct.TensorType(name="pred_bubble_logit"),
        ],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )

    mlmodel.author = "Liquid Analyzer Architecture Group"
    mlmodel.license = "Proprietary"
    mlmodel.short_description = (
        "MatterJEA multi-scale dilated 1D ultrasonic wave encoder (LA-ML-ARCH-001 v1.0.0)"
    )
    mlmodel.save(output_path)
    print(f"[MatterJEA] Exported FP16 CoreML package -> {output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Export MatterJEA AcousticWaveEncoder to CoreML FP16")
    parser.add_argument("--weights", type=str, default=None, help="Optional .pt checkpoint path")
    parser.add_argument("--out", type=str, default="MatterAcousticEncoder.mlpackage")
    parser.add_argument("--samples", type=int, default=8800)
    args = parser.parse_args()
    export_encoder_to_coreml(
        weights_path=args.weights,
        output_path=args.out,
        sample_length=args.samples,
    )


if __name__ == "__main__":
    main()
