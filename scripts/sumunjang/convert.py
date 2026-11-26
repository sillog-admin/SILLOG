"""Converts the trained SUMUNJANG model to Core ML and publishes it on Hugging Face.

The app (`SumunjangModel.swift`) downloads sumunjang.json, tokenizer/ and coreml/ from the repo and scores a screen
record the way `Scorer` below does: the record text is cut into token windows that repeat its header, and the record
score is the highest 1 - P(none) over its windows.

usage: python convert.py MODEL_DIR OUT_DIR [--val records.jsonl --reference reference.json] [--upload REPO]
needs: pip install torch transformers safetensors huggingface_hub coremltools
MODEL_DIR holds rl_agent_config.json, encoder/, tokenizer/, model.safetensors and questions.json.
--upload creates REPO as private; make it public by hand after the Mac check (`sillogctl sumunjang-check`).
"""
import argparse
import json
import lzma
import os
import shutil

import numpy as np
import torch
import torch.nn as nn
from safetensors.torch import load_file
from transformers import AutoConfig, AutoModel, AutoTokenizer

BASE_REPO, BASE_REVISION = "convaiinnovations/laya-multilingual", "92d22143468d8af669dc1a5a0480a2b21b4fe56e"
MAX_LEN, HEAD_MAX_LEN, OVERLAP, MARGIN, THRESHOLD = 512, 256, 64, 6, 0.8


class DecisionModel(nn.Module):
    """laya.common.DecisionModel in the sequential option layout the model was trained with."""

    def __init__(self, encoder, head_layers):
        super().__init__()
        self.encoder = encoder
        d = encoder.config.hidden_size
        layer = nn.TransformerEncoderLayer(d, d // 64, 4 * d, 0.1, batch_first=True, norm_first=True)
        self.head = nn.TransformerEncoder(layer, head_layers, enable_nested_tensor=False)
        self.type_emb = nn.Embedding(3, d)
        self.scorer = nn.Sequential(nn.LayerNorm(d), nn.Linear(d, d), nn.GELU(), nn.Linear(d, 1))
        self.act_head = nn.Sequential(nn.Linear(d + 4, 256), nn.GELU(), nn.Linear(256, 2))  # unused, kept for strict loading
        self.register_buffer("temperature", torch.ones(3))

    def forward(self, ids, att, markers):
        h = self.encoder(input_ids=ids, attention_mask=att).last_hidden_state
        h = h + self.type_emb.weight[0]                     # qtype 0 = choice
        for layer in self.head.layers:
            h = layer(h, src_key_padding_mask=~att.bool())
        m = torch.gather(h, 1, markers[:, :, None].expand(-1, -1, h.size(-1)))
        return self.scorer(m).squeeze(-1).float()


class Fixed(nn.Module):
    """One padded (1, MAX_LEN) window in, option probabilities out; the head's marker positions are baked in."""

    def __init__(self, model, markers):
        super().__init__()
        self.model = model
        self.register_buffer("markers", torch.tensor([markers]))

    def forward(self, input_ids, attention_mask):
        return torch.softmax(self.model(input_ids, attention_mask, self.markers), -1)


class Scorer:
    """The scoring the renewal test used (AJOU-SILLOG scripts/laya/serve.py)."""

    def __init__(self, model_dir):
        cfg = json.load(open(os.path.join(model_dir, "rl_agent_config.json")))
        self.question = json.load(open(os.path.join(model_dir, "questions.json"), encoding="utf-8"))["privacy"]
        self.options = list(self.question["criteria"])
        self.tok = AutoTokenizer.from_pretrained(os.path.join(model_dir, "tokenizer"))
        ecfg = AutoConfig.from_pretrained(os.path.join(model_dir, "encoder"))
        ecfg.reference_compile = False
        # eager: the sdpa and flash paths do not trace into Core ML ops.
        self.model = DecisionModel(AutoModel.from_config(ecfg, attn_implementation="eager"), cfg["head_layers"])
        self.model.load_state_dict(load_file(os.path.join(model_dir, "model.safetensors")), strict=True)
        self.device = "cuda" if torch.cuda.is_available() else "cpu"
        self.model.float().eval().to(self.device)
        self.head, self.markers = self._head()
        self.room = MAX_LEN - len(self.head) - 1

    def _ids(self, text, **kw):
        return self.tok(text.replace(self.tok.mask_token, " "), add_special_tokens=False, **kw)["input_ids"]

    def _head(self):
        """[CLS] choice question: <ins> [SEP] [MASK] opt0 [MASK] opt1 ... [SEP], as laya.common.build_head."""
        opt_ids = [[self.tok.mask_token_id] + self._ids(" %s: %s" % (k, v), truncation=True, max_length=48)
                   for k, v in self.question["criteria"].items()]
        budget = HEAD_MAX_LEN - sum(len(o) for o in opt_ids)
        assert budget >= 16, "options no longer fit the head"
        ids = [self.tok.cls_token_id] + self._ids("choice question: " + self.question["instructions"])[:max(8, budget)] \
            + [self.tok.sep_token_id]
        markers = []
        for o in opt_ids:
            markers.append(len(ids))
            ids += o
        return ids + [self.tok.sep_token_id], markers

    @staticmethod
    def header(rec):
        def trunc(s, n):
            s = str(s).replace("\n", " ").strip()
            return s if len(s) <= n else s[: n - 1] + "…"
        parts = ["[앱] %s (%s, %s)" % (rec.get("app") or "-", rec.get("app_kind") or "-", rec.get("capture_source") or "-")]
        for key, label in (("window_title", "[창] "), ("url", "[URL] "), ("doc_path", "[경로] ")):
            if rec.get(key):
                parts.append(label + trunc(rec[key], 120))
        return "\n".join(parts) + "\n[화면]\n"

    def windows(self, rec):
        text = (rec.get("text") or "").replace("{n}", "3").replace(self.tok.mask_token, " ")
        header = self.header(rec)
        budget = max(64, self.room - len(self._ids(header)) - MARGIN)
        offs = self.tok(text, add_special_tokens=False, return_offsets_mapping=True)["offset_mapping"]
        if not offs:
            return [header]
        out, i, stride = [], 0, max(16, budget - OVERLAP)
        while True:
            j = min(len(offs), i + budget)
            out.append(header + text[offs[i][0]:offs[j - 1][1]])
            if j >= len(offs):
                return out
            i += stride

    def sequence(self, state):
        return self.head + self._ids(state)[:MAX_LEN][: self.room] + [self.tok.sep_token_id]

    @torch.inference_mode()
    def probabilities(self, seqs, batch=16):
        out = []
        for k in range(0, len(seqs), batch):
            part = seqs[k:k + batch]
            width = max(len(s) for s in part)
            ids = torch.full((len(part), width), self.tok.pad_token_id, dtype=torch.long)
            att = torch.zeros((len(part), width), dtype=torch.long)
            for r, s in enumerate(part):
                ids[r, :len(s)] = torch.tensor(s)
                att[r, :len(s)] = 1
            logits = self.model(ids.to(self.device), att.to(self.device), torch.tensor([self.markers] * len(part), device=self.device))
            out += torch.softmax(logits, -1).tolist()
        return out

    def padded(self, seq):
        ids = torch.full((1, MAX_LEN), self.tok.pad_token_id, dtype=torch.long)
        att = torch.zeros((1, MAX_LEN), dtype=torch.long)
        ids[0, :len(seq)] = torch.tensor(seq)
        att[0, :len(seq)] = 1
        return ids, att


def reference(scorer, records_path, out_path):
    """Writes PyTorch scores and window ids for each record so the Mac can compare Core ML against them."""
    opener = lzma.open if records_path.endswith(".xz") else open
    recs = [json.loads(l) for l in opener(records_path, "rt", encoding="utf-8") if l.strip()]
    recs = [r for r in recs if r.get("split", "val") == "val"]
    owner, seqs = [], []
    for r, rec in enumerate(recs):
        for state in scorer.windows(rec):
            owner.append(r)
            seqs.append(scorer.sequence(state))
    probs = scorer.probabilities(seqs)
    out = [{"id": rec["id"], "score": 0.0, "windows": []} for rec in recs]
    for r, seq, p in zip(owner, seqs, probs):
        out[r]["windows"].append({"ids": seq, "score": round(1 - p[0], 6)})
        out[r]["score"] = max(out[r]["score"], round(1 - p[0], 6))
    json.dump({"threshold": THRESHOLD, "records": out}, open(out_path, "w"))
    print("reference", len(out), "records", len(seqs), "windows",
          sum(x["score"] >= THRESHOLD for x in out), "at or above", THRESHOLD, flush=True)
    return seqs[:8], probs[:8]


def _patch_coremltools():
    """Two gaps of coremltools 9.0 that ModernBERT under transformers 5 and numpy 2 runs into."""
    from coremltools.converters.mil import Builder as mb, register_torch_op
    from coremltools.converters.mil.frontend.torch import ops
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs

    @register_torch_op
    def new_ones(context, node):
        # transformers' mask helpers make a constant True with q_idx.new_ones((), dtype=torch.bool).
        inputs = _get_inputs(context, node)
        shape = inputs[1]
        dims = [int(v.val) for v in shape] if isinstance(shape, (list, tuple)) else [int(v) for v in np.reshape(shape.val, -1)]
        dtype = inputs[2].val if len(inputs) > 2 and inputs[2] is not None else None
        context.add(mb.const(val=np.ones(dims, dtype=np.bool_ if dtype == 11 else np.float32), name=node.name))

    cast = ops._cast

    def cast_item(context, node, dtype, dtype_name):
        # numpy 2 refuses int() of a one-element array, which coremltools folds constants with.
        x = _get_inputs(context, node, expected=1)[0]
        if x.can_be_folded_to_const() and not isinstance(x.val, dtype):
            context.add(mb.const(val=dtype(np.asarray(x.val).item()), name=node.name), node.name)
        else:
            cast(context, node, dtype, dtype_name)

    ops._cast = cast_item

def convert(scorer, out_dir, check):
    import coremltools as ct
    _patch_coremltools()
    torch.backends.mha.set_fastpath_enabled(False)           # the fused encoder-layer op has no Core ML form
    fixed = Fixed(scorer.model.cpu(), scorer.markers).eval()  # traced on CPU, whatever scored the reference
    example = scorer.padded(check[0][0])
    with torch.no_grad():
        traced = torch.jit.trace(fixed, example)
        # Padding to MAX_LEN must not move the scores the batched path gives.
        diffs = [float(np.abs(traced(*scorer.padded(s))[0].numpy() - np.array(p)).max()) for s, p in zip(*check)]
    print("traced vs batched max diff", max(diffs), flush=True)
    assert max(diffs) < 1e-3, diffs
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType("input_ids", shape=(1, MAX_LEN), dtype=np.int32),
                ct.TensorType("attention_mask", shape=(1, MAX_LEN), dtype=np.int32)],
        outputs=[ct.TensorType("probs")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    mlmodel.short_description = "SUMUNJANG: sensitive information in a screen record window"
    os.makedirs(os.path.join(out_dir, "coreml"), exist_ok=True)
    mlmodel.save(os.path.join(out_dir, "coreml", "Sumunjang.mlpackage"))


def write_files(scorer, model_dir, out_dir):
    tok = scorer.tok
    json.dump({
        "max_len": MAX_LEN, "overlap": OVERLAP, "margin": MARGIN, "threshold": THRESHOLD,
        "head_ids": scorer.head, "markers": scorer.markers,
        "sep_id": tok.sep_token_id, "pad_id": tok.pad_token_id, "mask_token": tok.mask_token,
        "options": scorer.options,
    }, open(os.path.join(out_dir, "sumunjang.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    tok.save_pretrained(os.path.join(out_dir, "tokenizer"))
    pt = os.path.join(out_dir, "pytorch")
    os.makedirs(pt, exist_ok=True)
    for name in ("rl_agent_config.json", "model.safetensors", "questions.json"):
        shutil.copy(os.path.join(model_dir, name), pt)
    shutil.copytree(os.path.join(model_dir, "encoder"), os.path.join(pt, "encoder"), dirs_exist_ok=True)
    shutil.copytree(os.path.join(model_dir, "tokenizer"), os.path.join(pt, "tokenizer"), dirs_exist_ok=True)
    from huggingface_hub import HfApi
    license_ = (HfApi().model_info(BASE_REPO, revision=BASE_REVISION).card_data or {}).get("license") or "other"
    here = os.path.dirname(os.path.abspath(__file__))
    card = open(os.path.join(here, "model_card.md"), encoding="utf-8").read()
    card = card.replace("{license}", license_).replace("{base}", BASE_REPO).replace("{base_revision}", BASE_REVISION)
    open(os.path.join(out_dir, "README.md"), "w", encoding="utf-8").write(card)
    print("base license", license_, flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model_dir")
    ap.add_argument("out_dir")
    ap.add_argument("--val", required=True, help="synthetic records (.jsonl or .jsonl.xz); split=val rows are scored")
    ap.add_argument("--reference", required=True, help="where to write PyTorch scores for the Mac check")
    ap.add_argument("--upload", help="Hugging Face repo id, created private")
    args = ap.parse_args()
    torch.set_num_threads(os.cpu_count() or 1)  # Colab starts torch on one thread
    os.makedirs(args.out_dir, exist_ok=True)
    scorer = Scorer(args.model_dir)
    check = reference(scorer, args.val, args.reference)
    write_files(scorer, args.model_dir, args.out_dir)
    convert(scorer, args.out_dir, check)
    if args.upload:
        from huggingface_hub import HfApi
        api = HfApi()
        api.create_repo(args.upload, private=True, exist_ok=True)
        info = api.upload_folder(folder_path=args.out_dir, repo_id=args.upload, commit_message="Add SUMUNJANG")
        print("uploaded", info.oid, flush=True)


if __name__ == "__main__":
    main()
