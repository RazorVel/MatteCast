# RVM model

MatteCast uses the official Robust Video Matting MobileNetV3 FP32 ONNX model.
MatteCast v1.0.0 bundles the pinned model in this repository so a checkout does
not depend on the upstream release remaining available. The model retains its
upstream license and is not covered by MatteCast's MIT license.

To restore or re-fetch the exact pinned artifact, run:

```bash
./scripts/fetch-rvm-model.sh
```

Expected artifact:

```text
models/rvm_mobilenetv3_fp32.onnx
```

Pinned provenance:

- upstream: `PeterL1n/RobustVideoMatting`
- release: `v1.0.0`
- size: `14975696` bytes
- SHA-256: `88d4531297118f595bf2fd60f6f566aec2e559393802d1f436c380f0cbbd2828`

The upstream project states that its code and pretrained models are published
under GPL-3.0. See `THIRD_PARTY_NOTICES.md` before redistributing a package or
container image that contains the model.
