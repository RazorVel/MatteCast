# Third-Party Notices

## Project origin

MatteCast is derived from the original BluCast project. The retained MIT
license and original copyright notice remain in `LICENSE`.

MatteCast source is MIT-licensed. Components obtained or installed separately
retain their own licenses and terms.

## Robust Video Matting (RVM)

Upstream: `PeterL1n/RobustVideoMatting`

The upstream project states that its code and pretrained models are published
under GPL-3.0. MatteCast v1.0.0 includes the pinned RVM MobileNetV3 ONNX model at
`models/rvm_mobilenetv3_fp32.onnx` for reproducibility and availability. The model
is a separately licensed third-party artifact and is not covered by MatteCast's
MIT license.

`scripts/fetch-rvm-model.sh` can restore the exact pinned upstream artifact after
verifying its expected size and SHA-256. Review and satisfy the applicable
upstream license obligations before redistributing the model or a combined
package/image that contains it.

## ONNX Runtime

Upstream: `microsoft/onnxruntime`

ONNX Runtime is MIT-licensed by Microsoft Corporation. The local container
build downloads a SHA-256-pinned official ONNX Runtime GPU release archive.

## Qt for Python / PySide6 Essentials / shiboken6

Upstream: Qt for Python / Qt Project.

PySide6 is offered under open-source LGPLv3/GPLv2 terms and commercial terms.
This build uses only the Essentials and shiboken6 wheels needed by the GUI, with
exact versions and PyPI-published SHA-256 hashes.

## OpenCV

OpenCV is distributed under the Apache License 2.0 for current releases.

## v4l2loopback

The v4l2loopback kernel module is distributed under GPL-2.0-or-later terms by
its upstream authors. MatteCast installs/loads the host distribution's package;
it does not bundle the kernel module in this source archive.

## NVIDIA CUDA / cuDNN container components

The container base provides NVIDIA CUDA and cuDNN runtime components. Those
components are governed by NVIDIA's applicable container/component license
terms and are not relicensed by MatteCast.

## Distribution note

The locally built runtime image contains third-party binaries and the bundled RVM
model. Before redistributing that image, preserve all applicable license notices
and satisfy each component's redistribution terms.
