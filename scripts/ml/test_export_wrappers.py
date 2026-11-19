import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))

try:
    import torch
    from transformers import T5Config, T5ForConditionalGeneration
    HAS_TORCH_HF = True
except Exception:
    HAS_TORCH_HF = False


@unittest.skipUnless(HAS_TORCH_HF, "torch/transformers not available in sandbox python")
class TestExportWrappers(unittest.TestCase):
    def test_encoder_and_decoder_wrappers_trace_cleanly(self):
        from export_coreml import T5DecoderWrapper, T5EncoderWrapper

        cfg = T5Config(
            vocab_size=320,
            d_model=64,
            d_kv=16,
            d_ff=128,
            num_layers=2,
            num_decoder_layers=2,
            num_heads=4,
            tie_word_embeddings=False,
        )
        model = T5ForConditionalGeneration(cfg).eval()
        enc = T5EncoderWrapper(model).eval()
        dec = T5DecoderWrapper(model).eval()

        enc_ids = torch.ones((1, 128), dtype=torch.int32)
        enc_mask = torch.ones((1, 128), dtype=torch.int32)
        traced_enc = torch.jit.trace(enc, (enc_ids, enc_mask))
        hidden = traced_enc(enc_ids, enc_mask)
        self.assertEqual(tuple(hidden.shape), (1, 128, 64))

        dec_ids = torch.zeros((1, 16), dtype=torch.int32)
        traced_dec = torch.jit.trace(dec, (dec_ids, hidden, enc_mask))
        logits = traced_dec(dec_ids, hidden, enc_mask)
        self.assertEqual(tuple(logits.shape), (1, 16, 320))


if __name__ == "__main__":
    unittest.main()
