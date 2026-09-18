#!/usr/bin/env python3
"""Replicate-aware inference with the ten official OpDetect model folds.

Biological replicates remain separate.  The fixed six-channel neural-network
input is filled with balanced forward and reverse cyclic arrangements, and all
fold/arrangement probabilities are averaged.  This reduces the bias caused by
silently copying only the first replicate or by one arbitrary channel order.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import sys
import zipfile
from pathlib import Path
from typing import Any

# Configure TensorFlow before it is imported anywhere.
os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "3")
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "-1")
os.environ.setdefault("TF_ENABLE_ONEDNN_OPTS", "1")

import numpy as np
import pandas as pd
from sklearn.metrics import classification_report, f1_score, recall_score, roc_auc_score

MODEL_CHANNELS = 6


def emit_gui_progress(percent: int, message: str) -> None:
    line = f"OPDETECT_PROGRESS\t8\t{percent}\tprogress\t{message}"
    print(line, flush=True)
    progress_file = os.environ.get("OPDETECT_PROGRESS_FILE")
    if progress_file:
        try:
            with open(progress_file, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        except OSError:
            pass


def archive_keras_version(path: Path) -> str | None:
    try:
        with zipfile.ZipFile(path) as archive:
            with archive.open("metadata.json") as handle:
                metadata = json.load(handle)
        value = metadata.get("keras_version")
        return str(value) if value else None
    except (OSError, KeyError, zipfile.BadZipFile, json.JSONDecodeError):
        return None


def build_network(model_factory: Any, hp: dict[str, Any], input_shape: tuple[int, ...]) -> Any:
    # The upstream model() function prints a complete summary on every call.
    # Capture it so the exported run log remains concise.
    with contextlib.redirect_stdout(io.StringIO()):
        return model_factory(
            input_shape=input_shape,
            num_labels=hp["num_labels"],
            lstm_units=hp["lstm_units"],
            cnn_filters=hp["cnn_filters"],
            F=hp["F"],
            D=hp["D"],
            kernel_size=hp["kernel_size"],
            dropout_rate=hp["dropout_rate"],
        )


def load_official_model(
    weights_path: Path,
    model_factory: Any,
    self_attention_class: Any,
    hp: dict[str, Any],
    input_shape: tuple[int, ...],
) -> tuple[Any, str]:
    import keras

    recorded = archive_keras_version(weights_path)
    network = build_network(model_factory, hp, input_shape)
    try:
        network.load_weights(str(weights_path))
        return network, "Keras weight archive"
    except Exception as weight_error:
        try:
            loaded = keras.models.load_model(
                str(weights_path),
                custom_objects={"SelfAttention": self_attention_class},
                compile=False,
                safe_mode=False,
            )
            return loaded, "complete Keras model"
        except Exception as model_error:
            version_note = f" (archive Keras {recorded})" if recorded else ""
            raise RuntimeError(
                f"Could not load official model file {weights_path}{version_note}.\n"
                f"Weight-loading error: {weight_error}\n"
                f"Full-model loading error: {model_error}\n"
                "Run 'Install or repair' so the environment uses TensorFlow 2.19 "
                "and Keras 3.9."
            ) from model_error


def balanced_channel_maps(replicate_count: int) -> list[list[int]]:
    """Return deterministic balanced six-channel replicate arrangements.

    Forward and reverse cyclic orders are used and duplicates removed.  For
    three replicates this produces all six permutations; for larger replicate
    counts it provides a bounded, balanced consensus without factorial growth.
    """
    if replicate_count == 1:
        return [[0] * MODEL_CHANNELS]

    maps: list[list[int]] = []
    seen: set[tuple[int, ...]] = set()
    bases = [list(range(replicate_count)), list(reversed(range(replicate_count)))]
    for base in bases:
        for shift in range(replicate_count):
            rotated = base[shift:] + base[:shift]
            mapping = tuple(rotated[index % replicate_count] for index in range(MODEL_CHANNELS))
            if mapping not in seen:
                seen.add(mapping)
                maps.append(list(mapping))
    return maps


def make_model_input(replicate_tensor: np.ndarray, mapping: list[int]) -> np.ndarray:
    # replicate_tensor: pair x replicate x position x feature
    selected = replicate_tensor[:, mapping, :, :]
    # model input: pair x position x six channels x three features
    return np.transpose(selected, (0, 2, 1, 3)).astype(np.float32, copy=False)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--processed", required=True, type=Path)
    parser.add_argument("--gene-pairs", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--arrangement-map-output", type=Path)
    parser.add_argument("--model-name", default="OpDetect")
    parser.add_argument("--threshold", default=0.5, type=float)
    parser.add_argument("--min-support", default=0.60, type=float)
    args = parser.parse_args()

    if not 0.0 <= args.threshold <= 1.0:
        raise SystemExit("--threshold must be between 0 and 1")
    if not 0.0 <= args.min_support <= 1.0:
        raise SystemExit("--min-support must be between 0 and 1")

    import keras
    import tensorflow as tf

    print(
        f"TensorFlow CPU mode active: TensorFlow {tf.__version__}; Keras {keras.__version__}",
        flush=True,
    )
    keras_major_minor = tuple(int(part) for part in keras.__version__.split(".")[:2])
    tf_major_minor = tuple(int(part) for part in tf.__version__.split(".")[:2])
    if keras_major_minor < (3, 9) or tf_major_minor < (2, 19):
        raise SystemExit(
            "The official OpDetect checkpoints require the repaired model environment. "
            f"Detected TensorFlow {tf.__version__} and Keras {keras.__version__}. "
            "Open the Windows GUI and click 'Install or repair'."
        )

    train_dir = (args.repo / "5_train").resolve()
    sys.path.insert(0, str(train_dir))
    from attention_layer import SelfAttention  # type: ignore
    from model import model  # type: ignore

    with (train_dir / "hyp.json").open("r", encoding="utf-8") as handle:
        hp = json.load(handle)

    # Files produced by early replicate-aware Windows builds stored string
    # arrays with NumPy object dtype.  Those internally generated arrays require
    # pickle support when read, even though the numeric tensor itself does not.
    # New builds save strings as native Unicode arrays, but allow_pickle=True is
    # retained here so an interrupted older run can be resumed without repeating
    # FASTQ quality control and alignment.
    with np.load(args.processed, allow_pickle=True) as loaded:
        replicate_tensor = loaded["replicate_tensor"].astype(np.float32, copy=False)
        names_1 = np.asarray(loaded["name_1"], dtype=str)
        names_2 = np.asarray(loaded["name_2"], dtype=str)
        labels_true = loaded["label"].astype(int)
        replicate_names = np.asarray(loaded["replicate_names"], dtype=str).tolist()

    if replicate_tensor.ndim != 4 or replicate_tensor.shape[2:] != (150, 3):
        raise SystemExit(
            f"Unexpected replicate-aware input shape: {replicate_tensor.shape}; "
            "expected pair x replicate x 150 x 3"
        )
    pair_count, replicate_count = replicate_tensor.shape[:2]
    if pair_count == 0:
        raise SystemExit("The processed OpDetect dataset contains no gene pairs")
    if not 1 <= replicate_count <= MODEL_CHANNELS:
        raise SystemExit(f"Expected 1 to {MODEL_CHANNELS} biological replicates")

    channel_maps = balanced_channel_maps(replicate_count)
    print(
        f"Replicate-aware consensus: {replicate_count} real replicate(s), "
        f"{len(channel_maps)} balanced channel arrangement(s), 10 model folds"
    )
    if replicate_count == 1:
        print(
            "WARNING: Only one biological replicate was supplied. The model can run, "
            "but replicate-to-replicate robustness cannot be assessed."
        )
    else:
        print("Replicates kept separate; no coverage averaging was performed.")

    if args.arrangement_map_output:
        args.arrangement_map_output.parent.mkdir(parents=True, exist_ok=True)
        arrangement_rows = []
        for arrangement_index, mapping in enumerate(channel_maps, start=1):
            arrangement_rows.append(
                {
                    "arrangement": arrangement_index,
                    **{
                        f"channel_{channel + 1}": replicate_names[replicate_index]
                        for channel, replicate_index in enumerate(mapping)
                    },
                }
            )
        pd.DataFrame(arrangement_rows).to_csv(
            args.arrangement_map_output, sep="\t", index=False
        )

    data_pairs = pd.DataFrame({"name_1": names_1, "name_2": names_2})
    output = pd.read_csv(args.gene_pairs)[["name_1", "name_2", "label"]].copy()
    output.rename(columns={"label": "true"}, inplace=True)

    model_dir = args.repo / "0_data" / "models" / "versions"
    all_predictions: list[np.ndarray] = []
    fold_means: list[np.ndarray] = []
    fold_order_sds: list[np.ndarray] = []
    architecture_printed = False

    for fold in range(10):
        start_percent = 80 + fold
        finish_percent = 81 + fold
        emit_gui_progress(start_percent, f"Loading and predicting with model {fold + 1} of 10")
        model_path = model_dir / f"{args.model_name}_best_model__fold_{fold}.keras"
        if not model_path.exists():
            raise FileNotFoundError(f"Missing supplied model file: {model_path}")

        keras.backend.clear_session()
        network, loading_method = load_official_model(
            model_path,
            model,
            SelfAttention,
            hp,
            (150, MODEL_CHANNELS, 3),
        )
        expected_shape = tuple(network.input_shape[1:])
        if expected_shape != (150, MODEL_CHANNELS, 3):
            raise RuntimeError(
                f"Model {fold + 1} expects input {expected_shape}, not (150, 6, 3)."
            )
        if not architecture_printed:
            print(
                f"Model architecture verified: input {expected_shape}; "
                f"parameters {network.count_params():,}"
            )
            architecture_printed = True
        print(f"Loaded model {fold + 1} using {loading_method}", flush=True)

        arrangement_predictions: list[np.ndarray] = []
        for mapping in channel_maps:
            x = make_model_input(replicate_tensor, mapping)
            probability = network.predict(x, verbose=0)[:, 1].astype(np.float32)
            arrangement_predictions.append(probability)
            all_predictions.append(probability)
            del x

        arrangement_matrix = np.stack(arrangement_predictions, axis=0)
        fold_mean = arrangement_matrix.mean(axis=0)
        fold_order_sd = arrangement_matrix.std(axis=0)
        fold_means.append(fold_mean)
        fold_order_sds.append(fold_order_sd)

        direct = {
            (str(a), str(b)): float(p)
            for (a, b), p in zip(data_pairs.to_numpy(), fold_mean)
        }
        output[f"prob_{fold}"] = [
            direct.get((str(a), str(b)), direct.get((str(b), str(a)), np.nan))
            for a, b in output[["name_1", "name_2"]].to_numpy()
        ]
        emit_gui_progress(finish_percent, f"Finished pretrained model {fold + 1} of 10")
        del network
        keras.backend.clear_session()

    pooled = np.stack(all_predictions, axis=0)
    fold_matrix = np.stack(fold_means, axis=0)
    order_sd_matrix = np.stack(fold_order_sds, axis=0)

    # The integrated and output pair order should match. Use a direct map anyway
    # so reversed strand pair names remain compatible with upstream behavior.
    pooled_mean = pooled.mean(axis=0)
    pooled_sd = pooled.std(axis=0)
    support = (pooled >= args.threshold).mean(axis=0)
    model_sd = fold_matrix.std(axis=0)
    replicate_order_sd = order_sd_matrix.mean(axis=0)
    summary = {
        (str(a), str(b)): (float(mean), float(sd), float(sup), float(msd), float(osd))
        for (a, b), mean, sd, sup, msd, osd in zip(
            data_pairs.to_numpy(),
            pooled_mean,
            pooled_sd,
            support,
            model_sd,
            replicate_order_sd,
        )
    }

    values = [
        summary.get((str(a), str(b)), summary.get((str(b), str(a))))
        for a, b in output[["name_1", "name_2"]].to_numpy()
    ]
    output["prob"] = [value[0] if value else np.nan for value in values]
    output["prediction_sd"] = [value[1] if value else np.nan for value in values]
    output["support_fraction"] = [value[2] if value else np.nan for value in values]
    output["model_fold_sd"] = [value[3] if value else np.nan for value in values]
    output["replicate_order_sd"] = [value[4] if value else np.nan for value in values]
    output["pred"] = np.where(
        output["prob"].isna(), np.nan, (output["prob"] >= args.threshold).astype(int)
    )
    output["robust_pred"] = np.where(
        output["prob"].isna(),
        np.nan,
        (
            (output["prob"] >= args.threshold)
            & (output["support_fraction"] >= args.min_support)
        ).astype(int),
    )
    output["real_replicates"] = replicate_count
    output["consensus_arrangements"] = len(channel_maps)
    output["minimum_support_required"] = args.min_support

    args.output.parent.mkdir(parents=True, exist_ok=True)
    output.to_csv(args.output, index=False)
    print(f"Wrote {len(output)} replicate-aware gene-pair predictions to {args.output}")
    print(
        f"Robust positives require mean probability >= {args.threshold:.2f} and "
        f"support fraction >= {args.min_support:.2f}."
    )

    evaluated = output[
        output["true"].isin([0, 1]) & output["robust_pred"].notna()
    ].copy()
    if not evaluated.empty:
        y_true = evaluated["true"].astype(int)
        y_pred = evaluated["robust_pred"].astype(int)
        print(classification_report(y_true, y_pred, digits=3))
        print(f"F1: {f1_score(y_true, y_pred):.3f}")
        print(f"Recall: {recall_score(y_true, y_pred):.3f}")
        if y_true.nunique() == 2:
            print(f"AUROC: {roc_auc_score(y_true, evaluated['prob']):.3f}")
    else:
        print("No known 0/1 labels supplied; evaluation metrics were skipped.")


if __name__ == "__main__":
    main()
