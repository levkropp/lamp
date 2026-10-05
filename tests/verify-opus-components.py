#!/usr/bin/env python3
"""Runs LAMP's 35 Opus component suites against the RFC 6716 reference with the
RFC 8251 decoder update. No FFmpeg or audio device is needed.

usage: python3 tests/verify-opus-components.py [suite ...]

Each suite verifies the committed tables still match the normative source,
builds a test-only oracle from reference C and the assembly library, runs it,
and writes <out>/opus-<suite>-verification.json. Run
tests/verify-opus-conformance.py separately for the official vectors.
"""
from dataclasses import dataclass, field
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lamp_test import (GENERATED, GENERATED_INCLUDE, OPUS_REFERENCE, TESTS, WINDOWS, Failure, build_lamp,
                       compile_c, exe, main_guard, node, opus_reference, out_dir, run, silk_float_sources,
                       write_report)


@dataclass
class Suite:
    name: str
    tables: list = field(default_factory=list)   # (generator, None | '--check' | 'GENERATED')
    sources: list = field(default_factory=list)  # tests/ file, '@' reference file, '%' generated file
    defines: list = field(default_factory=list)
    includes: list = field(default_factory=list)  # reference subdirectories
    fp: str = 'precise'
    generated: bool = False                       # add tests/generated/include
    precise: list = field(default_factory=list)   # compiled separately with precise floating point
    args: list = field(default_factory=list)
    report: dict = field(default_factory=dict)


SUITES = [
    Suite('range',
          tables=[],
          sources=['opus-range-oracle.c', '@celt/entdec.c', '@celt/entcode.c'],
          defines=['OPUS_BUILD'], includes=['include', 'celt'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'operations': 524288, 'scope': 'range symbols, state, whole and fractional bit counts; not audio decoding', 'stats': None}),
    Suite('packet',
          tables=[],
          sources=['opus-packet-oracle.c'],
          defines=[], includes=[], fp='precise', generated=True,
          precise=[], args=[],
          report={'result': 'passed', 'reference': 'RFC6716 + RFC8251 for regular packets; test-only Opus1.5.2 parser (full opus.c SHA256 f5ae5ff3e9cef998addeee777dcb283cffcaf0f6ee4452108127e9157cdb2458) for self-delimited packets', 'scope': 'regular and RFC6716 AppendixB self-delimited packet framing, frame sizes/pointers, TOC/duration and consumed bytes including padding; protected-page boundaries and invalid/null API inputs; not audio decoding', 'stats': None}),
    Suite('cwrs',
          tables=[],
          sources=['opus-cwrs-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'CELT pulse enumeration and entropy state; not audio decoding', 'stats': None}),
    Suite('energy',
          tables=[],
          sources=['opus-energy-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@celt/laplace.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'CELT Laplace symbols, coarse/fine/final energy and entropy state; not audio decoding', 'stats': None}),
    Suite('silk-pulses',
          tables=[],
          sources=['opus-silk-pulses-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/decode_pulses.c', '@silk/shell_coder.c', '@silk/code_signs.c', '@silk/tables_pulses_per_block.c', '@silk/tables_other.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK shell trees, excitation pulses, LSB and signs, entropy state; not audio synthesis', 'stats': None}),
    Suite('silk-indices',
          tables=[('generate-silk-indices-tables.js', '--check')],
          sources=['opus-silk-indices-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/decode_indices.c', '@silk/NLSF_unpack.c', '@silk/decode_pulses.c', '@silk/shell_coder.c', '@silk/code_signs.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c', '@silk/tables_pulses_per_block.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK signal/gain/NLSF/pitch/LTP/seed side-information indices, NLSF selector/predictor unpack, persistent entropy-index state and connected excitation pulses', 'comparison': 'exact integer outputs, unused-field preservation and complete entropy state', 'stats': None}),
    Suite('silk-parameters',
          tables=[('generate-silk-parameters-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check')],
          sources=['opus-silk-parameters-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/decode_indices.c', '@silk/NLSF_unpack.c', '@silk/gain_quant.c', '@silk/log2lin.c', '@silk/lin2log.c', '@silk/decode_pitch.c', '@silk/pitch_est_tables.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=True,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK integer log-to-linear gain reconstruction, persistent gain-index state, pitch contour/clamping, Q14 LTP taps and scaling, connected side-information parameter sequences', 'comparison': 'exact integers and prior-gain state', 'stats': None}),
    Suite('silk-nlsf',
          tables=[('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check')],
          sources=['opus-silk-nlsf-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@silk/decode_indices.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK fixed-point NLSF codebook and predictive residual reconstruction, Laroia weights, integer square-root approximation, clipping and 20-iteration stabilization/fallback, including connected side information; invalid reference-result spacing/range is rejected before LPC conversion', 'comparison': 'exact integer vectors, residuals, weights and selectors, plus independent result-validity rejection checks', 'stats': None}),
    Suite('silk-lpc',
          tables=[('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check')],
          sources=['opus-silk-lpc-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@silk/NLSF2A.c', '@silk/LPC_inv_pred_gain.c', '@silk/bwexpander.c', '@silk/bwexpander_32.c', '@silk/table_LSF_cos.c', '@silk/NLSF_decode.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/decode_indices.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK fixed-point reciprocal, int16/int32 bandwidth expansion, inverse prediction gain and NLSF-to-Q12-LPC conversion, including connected reconstructed NLSF vectors', 'comparison': 'exact integer coefficients and stability/gain outputs', 'stats': None}),
    Suite('silk-state',
          tables=[('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check')],
          sources=['opus-silk-state-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@silk/decode_parameters.c', '@silk/gain_quant.c', '@silk/log2lin.c', '@silk/lin2log.c', '@silk/decode_pitch.c', '@silk/pitch_est_tables.c', '@silk/NLSF2A.c', '@silk/LPC_inv_pred_gain.c', '@silk/bwexpander.c', '@silk/bwexpander_32.c', '@silk/table_LSF_cos.c', '@silk/NLSF_decode.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/decode_indices.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'Complete SILK gain/NLSF/LPC/pitch/LTP parameter orchestration, previous gain/NLSF history, first-frame interpolation reset, interpolation and bandwidth expansion after loss; atomic public and invalid-NLSF failures', 'comparison': 'exact normative decoder controls, SideInfoIndices and parameter history', 'stats': None}),
    Suite('silk-prediction',
          tables=[],
          sources=['opus-silk-prediction-oracle.c', '@silk/LPC_analysis_filter.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK signed fixed-point division for gain adjustment and zero-state LPC analysis/rewhitening, including integer wrap/rounding/saturation and public guards', 'comparison': 'exact integers and complete output samples', 'stats': None}),
    Suite('silk-synthesis',
          tables=[('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check')],
          sources=['opus-silk-synthesis-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/decode_core.c', '@silk/LPC_analysis_filter.c', '@silk/decode_parameters.c', '@silk/gain_quant.c', '@silk/log2lin.c', '@silk/lin2log.c', '@silk/decode_pitch.c', '@silk/pitch_est_tables.c', '@silk/NLSF2A.c', '@silk/LPC_inv_pred_gain.c', '@silk/bwexpander.c', '@silk/bwexpander_32.c', '@silk/table_LSF_cos.c', '@silk/NLSF_decode.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/decode_indices.c', '@silk/decode_pulses.c', '@silk/shell_coder.c', '@silk/code_signs.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c', '@silk/tables_pulses_per_block.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK inverse-NSQ excitation/random signs, LTP rewhitening/prediction/gain scaling, LPC synthesis, int16 PCM saturation, loss-to-normal blending and core history, including connected indices/pulses/parameters', 'comparison': 'exact source-rate mono int16 PCM, excitation/LPC/output history and mutable controls', 'stats': None}),
    Suite('silk-resampler',
          tables=[('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check')],
          sources=['opus-silk-resampler-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/resampler.c', '@silk/resampler_private_up2_HQ.c', '@silk/resampler_private_AR2.c', '@silk/resampler_private_IIR_FIR.c', '@silk/resampler_private_down_FIR.c', '@silk/resampler_rom.c', '@silk/decode_core.c', '@silk/LPC_analysis_filter.c', '@silk/decode_parameters.c', '@silk/gain_quant.c', '@silk/log2lin.c', '@silk/lin2log.c', '@silk/decode_pitch.c', '@silk/pitch_est_tables.c', '@silk/NLSF2A.c', '@silk/LPC_inv_pred_gain.c', '@silk/bwexpander.c', '@silk/bwexpander_32.c', '@silk/table_LSF_cos.c', '@silk/NLSF_decode.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/decode_indices.c', '@silk/decode_pulses.c', '@silk/shell_coder.c', '@silk/code_signs.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c', '@silk/tables_pulses_per_block.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'All 15 SILK decoder input/output-rate pairs, delay compensation, raw up2/AR2, fractional up/down FIR, repeated whole-millisecond blocks, defined history and connected core PCM', 'comparison': 'exact PCM and defined persistent fields; complete RFC8251 resampler history checked, ASM unused tail preserved and checked across distinct scratch fills', 'stats': None}),
    Suite('silk-cng',
          tables=[('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check')],
          sources=['opus-silk-cng-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/CNG.c', '@silk/resampler.c', '@silk/resampler_private_up2_HQ.c', '@silk/resampler_private_AR2.c', '@silk/resampler_private_IIR_FIR.c', '@silk/resampler_private_down_FIR.c', '@silk/resampler_rom.c', '@silk/decode_core.c', '@silk/LPC_analysis_filter.c', '@silk/decode_parameters.c', '@silk/gain_quant.c', '@silk/log2lin.c', '@silk/lin2log.c', '@silk/decode_pitch.c', '@silk/pitch_est_tables.c', '@silk/NLSF2A.c', '@silk/LPC_inv_pred_gain.c', '@silk/bwexpander.c', '@silk/bwexpander_32.c', '@silk/table_LSF_cos.c', '@silk/NLSF_decode.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/decode_indices.c', '@silk/decode_pulses.c', '@silk/shell_coder.c', '@silk/code_signs.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c', '@silk/tables_pulses_per_block.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK comfort-noise rate resets, NLSF/gain smoothing, highest-gain excitation history, deterministic random residuals, LPC synthesis/history and saturated addition, including connected core/CNG/resampling', 'comparison': 'exact complete CNG state and int16 PCM, immutable input histories/controls and capacity/canary guards', 'stats': None}),
    Suite('silk-plc',
          tables=[('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check')],
          sources=['opus-silk-plc-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/PLC.c', '@silk/sum_sqr_shift.c', '@silk/CNG.c', '@silk/resampler.c', '@silk/resampler_private_up2_HQ.c', '@silk/resampler_private_AR2.c', '@silk/resampler_private_IIR_FIR.c', '@silk/resampler_private_down_FIR.c', '@silk/resampler_rom.c', '@silk/decode_core.c', '@silk/LPC_analysis_filter.c', '@silk/decode_parameters.c', '@silk/gain_quant.c', '@silk/log2lin.c', '@silk/lin2log.c', '@silk/decode_pitch.c', '@silk/pitch_est_tables.c', '@silk/NLSF2A.c', '@silk/LPC_inv_pred_gain.c', '@silk/bwexpander.c', '@silk/bwexpander_32.c', '@silk/table_LSF_cos.c', '@silk/NLSF_decode.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/decode_indices.c', '@silk/decode_pulses.c', '@silk/shell_coder.c', '@silk/code_signs.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c', '@silk/tables_pulses_per_block.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK energy, saved prediction/gain parameters, reset, repeated voiced/unvoiced loss concealment and energy recovery glue, including connected core/PLC/CNG/resampling', 'comparison': 'exact complete PLC/core/control state and int16 PCM, immutable parameter/indices, capacity/canary guards', 'stats': None}),
    Suite('silk-stereo',
          tables=[('generate-silk-stereo-tables.js', '--check')],
          sources=['opus-silk-stereo-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/stereo_decode_pred.c', '@silk/stereo_MS_to_LR.c', '@silk/tables_other.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK predictor and mid-only entropy decoding, adaptive mid/side reconstruction, interpolation, saturated left/right PCM and stereo history', 'comparison': 'exact complete entropy/stereo state and int16 PCM, capacity/canary guards', 'stats': None}),
    Suite('silk-frame',
          tables=[('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check')],
          sources=['opus-silk-frame-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/init_decoder.c', '@silk/decoder_set_fs.c', '@silk/decode_frame.c', '@silk/PLC.c', '@silk/sum_sqr_shift.c', '@silk/CNG.c', '@silk/resampler.c', '@silk/resampler_private_up2_HQ.c', '@silk/resampler_private_AR2.c', '@silk/resampler_private_IIR_FIR.c', '@silk/resampler_private_down_FIR.c', '@silk/resampler_rom.c', '@silk/decode_core.c', '@silk/LPC_analysis_filter.c', '@silk/decode_parameters.c', '@silk/gain_quant.c', '@silk/log2lin.c', '@silk/lin2log.c', '@silk/decode_pitch.c', '@silk/pitch_est_tables.c', '@silk/NLSF2A.c', '@silk/LPC_inv_pred_gain.c', '@silk/bwexpander.c', '@silk/bwexpander_32.c', '@silk/table_LSF_cos.c', '@silk/NLSF_decode.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/decode_indices.c', '@silk/decode_pulses.c', '@silk/shell_coder.c', '@silk/code_signs.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c', '@silk/tables_pulses_per_block.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK channel initialization/configuration, complete source-rate frame entropy/pulses/parameters/core/PLC/history/glue/CNG, loss/FEC and rate/reset transitions', 'comparison': 'exact full channel history, entropy and int16 PCM, sticky late failure/reset and public capacity/canary guards', 'stats': None}),
    Suite('silk-packet',
          tables=[('generate-silk-stereo-tables.js', '--check'), ('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check'), ('generate-silk-packet-reference.js', 'GENERATED')],
          sources=['opus-silk-packet-oracle.c', '%reference_header.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/init_decoder.c', '@silk/decoder_set_fs.c', '@silk/decode_frame.c', '@silk/stereo_decode_pred.c', '@silk/PLC.c', '@silk/sum_sqr_shift.c', '@silk/CNG.c', '@silk/resampler.c', '@silk/resampler_private_up2_HQ.c', '@silk/resampler_private_AR2.c', '@silk/resampler_private_IIR_FIR.c', '@silk/resampler_private_down_FIR.c', '@silk/resampler_rom.c', '@silk/decode_core.c', '@silk/LPC_analysis_filter.c', '@silk/decode_parameters.c', '@silk/gain_quant.c', '@silk/log2lin.c', '@silk/lin2log.c', '@silk/decode_pitch.c', '@silk/pitch_est_tables.c', '@silk/NLSF2A.c', '@silk/LPC_inv_pred_gain.c', '@silk/bwexpander.c', '@silk/bwexpander_32.c', '@silk/table_LSF_cos.c', '@silk/NLSF_decode.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/decode_indices.c', '@silk/decode_pulses.c', '@silk/shell_coder.c', '@silk/code_signs.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c', '@silk/tables_pulses_per_block.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'SILK packet VAD/LBRR flags, normal-playback FEC skipping, conditional redundancy, stereo predictors/mid-only flags and connected mono channel frames', 'comparison': 'exact metadata, complete channel/entropy history, connected mono PCM and capacity/canary guards against unchanged dec_API header block', 'stats': None}),
    Suite('silk-decoder',
          tables=[('generate-silk-stereo-tables.js', '--check'), ('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check'), ('generate-silk-packet-reference.js', '--check')],
          sources=['opus-silk-decoder-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@silk/dec_API.c', '@silk/stereo_decode_pred.c', '@silk/stereo_MS_to_LR.c', '@silk/init_decoder.c', '@silk/decoder_set_fs.c', '@silk/decode_frame.c', '@silk/PLC.c', '@silk/sum_sqr_shift.c', '@silk/CNG.c', '@silk/resampler.c', '@silk/resampler_private_up2_HQ.c', '@silk/resampler_private_AR2.c', '@silk/resampler_private_IIR_FIR.c', '@silk/resampler_private_down_FIR.c', '@silk/resampler_rom.c', '@silk/decode_core.c', '@silk/LPC_analysis_filter.c', '@silk/decode_parameters.c', '@silk/gain_quant.c', '@silk/log2lin.c', '@silk/lin2log.c', '@silk/decode_pitch.c', '@silk/pitch_est_tables.c', '@silk/NLSF2A.c', '@silk/LPC_inv_pred_gain.c', '@silk/bwexpander.c', '@silk/bwexpander_32.c', '@silk/table_LSF_cos.c', '@silk/NLSF_decode.c', '@silk/NLSF_unpack.c', '@silk/NLSF_VQ_weights_laroia.c', '@silk/NLSF_stabilize.c', '@silk/sort.c', '@silk/decode_indices.c', '@silk/decode_pulses.c', '@silk/shell_coder.c', '@silk/code_signs.c', '@silk/tables_other.c', '@silk/tables_gain.c', '@silk/tables_pitch_lag.c', '@silk/tables_LTP.c', '@silk/tables_NLSF_CB_NB_MB.c', '@silk/tables_NLSF_CB_WB.c', '@silk/tables_pulses_per_block.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt', 'silk'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'Complete SILK packet/API orchestration, mono/stereo/mid-only/channel and rate transitions, FEC/loss/recovery, output resampling and pitch', 'comparison': 'exact entropy, PCM and defined channel/stereo/resampler/packet history, deterministic distinct-scratch runs, sticky late failure/reset and public guards; complete RFC8251 resampler history checked; inactive right resampler reinitialized for stereo collapse with API-rate change', 'stats': None}),
    Suite('allocation',
          tables=[],
          sources=['opus-allocation-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA'], includes=['include', 'celt'], fp='precise', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'CELT static allocation, fine-bit split, band skipping, stereo decisions and entropy state; not audio decoding', 'stats': None}),
    Suite('vq',
          tables=[],
          sources=['opus-vq-oracle.c', '@celt/cwrs.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='strict', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'CELT normalized PVQ bands, spreading, collapse masks, unit norm and entropy state; not complete recursive bands or audio decoding', 'maximum_absolute_tolerance': 3e-06, 'stats': None}),
    Suite('band-transform',
          tables=[],
          sources=['opus-band-transform-oracle.c', '@celt/vq.c', '@celt/cwrs.c', '@celt/mathops.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='strict', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'CELT Haar time/frequency transforms and Hadamard interleave/deinterleave; not recursive bands or audio decoding', 'stats': None}),
    Suite('controls',
          tables=[('generate-celt-controls-reference.js', None)],
          sources=['opus-controls-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@celt/laplace.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='precise', generated=True,
          precise=[], args=['fixtures/tone.opus'],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'CELT frame flags, postfilter parameters, coarse/fine energy, TF decisions, dynamic/static allocation and entropy state; not shape synthesis or audio decoding', 'stats': None}),
    Suite('theta',
          tables=[('generate-celt-theta-reference.js', None)],
          sources=['opus-theta-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@celt/mathops.c', '@celt/vq.c', '@celt/cwrs.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='precise', generated=True,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'CELT recursive/stereo split angles, integer gains and allocation deltas, inversion/fill, entropy state and integer math; not recursive vector reconstruction or audio decoding', 'stats': None}),
    Suite('band',
          tables=[('generate-celt-bands-reference.js', None), ('generate-celt-controls-reference.js', None)],
          sources=['opus-band-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@celt/mathops.c', '@celt/vq.c', '@celt/cwrs.c', '@celt/laplace.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='strict', generated=True,
          precise=['@celt/quant_bands.c'], args=['fixtures/tone.opus'],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'normal-mode CELT recursive vectors and full spectral frame loop, stereo, folding, TF, collapse masks, exact entropy/budget/seed state and connected real-frame prefixes; not synthesis or audio decoding', 'vector_absolute_tolerance': 1e-05, 'folding_output_absolute_tolerance': 4e-05, 'stats': None}),
    Suite('spectral',
          tables=[('generate-celt-spectral-tables.js', '--check')],
          sources=['opus-spectral-oracle.c', '@celt/entdec.c', '@celt/entcode.c', '@celt/entenc.c', '@celt/mathops.c', '@celt/vq.c', '@celt/cwrs.c', '@celt/laplace.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='strict', generated=False,
          precise=['@celt/quant_bands.c'], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'normal-mode CELT transient anti-collapse, mean energy/exponent conversion and denormalization with all output-rate boundaries; not inverse MDCT or PCM decoding', 'anti_collapse_absolute_tolerance': 3e-06, 'spectral_relative_tolerance': 3e-07, 'exponent_maximum_ulp': 1, 'stats': None}),
    Suite('transform',
          tables=[('generate-celt-transform-tables.js', '--check')],
          sources=['opus-transform-oracle.c', '@celt/kiss_fft.c', '@celt/mdct.c', '@celt/mathops.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='strict', generated=True,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'normal-mode CELT mixed-radix inverse FFT, inverse MDCT/TDAC and long/transient mono/stereo overlap synthesis including state transitions; not postfilter or complete PCM decoding', 'scale_adjusted_absolute_tolerance': 3e-05, 'stats': None}),
    Suite('filter',
          tables=[('generate-celt-transform-tables.js', '--check')],
          sources=['opus-filter-oracle.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='strict', generated=True,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'CELT causal/window-transition comb postfilter, tapsets, standard-mode deemphasis, PCM scaling and all output rates with persistent memory; not complete Opus decoding', 'scale_adjusted_absolute_tolerance': 1e-05, 'stats': None}),
    Suite('lpc',
          tables=[],
          sources=['opus-lpc-oracle.c', '@celt/celt_lpc.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='strict', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'CELT float windowed autocorrelation, Levinson-Durbin LPC and stateful causal/in-place FIR/IIR kernels, also used by the separate CELT frame concealment suite', 'scale_adjusted_absolute_tolerance': 1e-05, 'stats': None}),
    Suite('pitch',
          tables=[],
          sources=['opus-pitch-oracle.c', '@celt/pitch.c', '@celt/celt_lpc.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt'], fp='strict', generated=False,
          precise=[], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'standard-mode CELT mono/stereo pitch downsample, LPC whitening, coarse/fine search and interpolation, also used by the separate CELT frame concealment suite', 'scale_adjusted_absolute_tolerance': 1e-05, 'stats': None}),
    Suite('decoder',
          tables=[],
          sources=['opus-decoder-oracle.c', '@celt/bands.c', '@celt/cwrs.c', '@celt/entcode.c', '@celt/entdec.c', '@celt/entenc.c', '@celt/kiss_fft.c', '@celt/laplace.c', '@celt/mathops.c', '@celt/mdct.c', '@celt/modes.c', '@celt/pitch.c', '@celt/celt_lpc.c', '@celt/rate.c', '@celt/vq.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt', 'src'], fp='strict', generated=True,
          precise=['@celt/quant_bands.c'], args=['fixtures/tone.opus'],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'stateful normal-mode CELT frame-to-float-PCM, pitch/LPC/noise concealment and recovery with persistent histories, mono/stereo conversion, all frame sizes/output rates/bandwidths and primed entropy contexts, malformed/truncated payloads and sticky failure/reset', 'scale_adjusted_absolute_tolerance': 4e-05, 'stats': None}),
    Suite('mode',
          tables=[('generate-silk-stereo-tables.js', '--check'), ('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check'), ('generate-celt-tables.js', '--check'), ('generate-silk-packet-reference.js', '--check')],
          sources=['opus-mode-oracle.c', '@celt/bands.c', '@celt/cwrs.c', '@celt/entcode.c', '@celt/entdec.c', '@celt/entenc.c', '@celt/kiss_fft.c', '@celt/laplace.c', '@celt/mathops.c', '@celt/mdct.c', '@celt/modes.c', '@celt/pitch.c', '@celt/celt_lpc.c', '@celt/rate.c', '@celt/vq.c', '@src/opus.c', '@src/opus_encoder.c', '@src/repacketizer.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt', 'src', 'silk', 'silk/float'], fp='strict', generated=True,
          precise=['@celt/quant_bands.c', 'SILK_SOURCES'], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'Complete SILK/hybrid/CELT mode frames, shared entropy, all32 TOC configurations, five output rates, mono/stereo conversion, FEC/loss/recovery, transition redundancy/crossfades, empty high-band PLC and defined persistent histories', 'comparison': 'exact mapped integer SILK history and defined resampler state; zero observed float PCM/CELT-history error at stated tolerance; deterministic complete ASM state with distinct scratch fills; RFC8251-updated full reference decoder and test-only encoder', 'scale_adjusted_absolute_tolerance': 4e-05, 'stats': None}),
    Suite('stream',
          tables=[('generate-silk-stereo-tables.js', '--check'), ('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check'), ('generate-celt-tables.js', '--check'), ('generate-silk-packet-reference.js', '--check')],
          sources=['opus-stream-oracle.c', '@celt/bands.c', '@celt/cwrs.c', '@celt/entcode.c', '@celt/entdec.c', '@celt/entenc.c', '@celt/kiss_fft.c', '@celt/laplace.c', '@celt/mathops.c', '@celt/mdct.c', '@celt/modes.c', '@celt/pitch.c', '@celt/celt_lpc.c', '@celt/rate.c', '@celt/vq.c', '@src/opus.c', '@src/opus_encoder.c', '@src/repacketizer.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt', 'src', 'silk', 'silk/float'], fp='strict', generated=True,
          precise=['@celt/quant_bands.c', 'SILK_SOURCES'], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'Complete regular and self-delimited Opus packet-to-PCM dispatch with trailing stream bytes and consumed-byte checks: four framing codes, CBR/VBR, padding, up to48 frames/120ms, all32 TOC configurations, five output rates, mono/stereo conversion, FEC/loss and zero/one-byte DTX; 2048 malformed packets, capacity/canary/immutable-input/sticky failure checks', 'comparison': 'exact mapped integer SILK history and defined resampler state; float PCM/CELT-history at stated tolerance; deterministic complete ASM state with distinct scratch fills; RFC8251-updated reference decoder and test-only encoder; Opus1.5.2 framing reference, with a wrapper observing intermediate CELT errors that later frames/resets can clear', 'scale_adjusted_absolute_tolerance': 4e-05, 'stats': None}),
    Suite('ogg',
          tables=[('generate-silk-stereo-tables.js', '--check'), ('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check'), ('generate-celt-tables.js', '--check'), ('generate-silk-packet-reference.js', '--check')],
          sources=['opus-ogg-oracle.c', '@celt/bands.c', '@celt/cwrs.c', '@celt/entcode.c', '@celt/entdec.c', '@celt/entenc.c', '@celt/kiss_fft.c', '@celt/laplace.c', '@celt/mathops.c', '@celt/mdct.c', '@celt/modes.c', '@celt/pitch.c', '@celt/celt_lpc.c', '@celt/rate.c', '@celt/vq.c', '@src/opus.c', '@src/opus_encoder.c', '@src/repacketizer.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt', 'src', 'silk', 'silk/float'], fp='strict', generated=True,
          precise=['@celt/quant_bands.c', 'SILK_SOURCES'], args=[],
          report={'result': 'passed', 'reference': OPUS_REFERENCE, 'scope': 'Single-stream Ogg/Opus mapping family0,48kHz stereo output,mono duplication,full signed Q8 gain,pre-skip0..65535,nonzero initial granule offsets,end trimming,continued tags/audio,compatible minor extensions,header placement/granule/framing/CRC/sequence bounds,late failure and cancellation', 'comparison': '393 generated streams against full RFC8251-updated native PCM,independent double-precision gain reference,4157 bounded read/canary checks,immutable mapped input,27 malformed stream rejections,late/sticky discard and2 cancellation checks; zero observed error without header gain and at most2.99e-7 scaled error across gain extremes', 'scale_adjusted_absolute_tolerance': 4e-05, 'stats': None}),
    Suite('multistream',
          tables=[('generate-silk-stereo-tables.js', '--check'), ('generate-silk-resampler-tables.js', '--check'), ('generate-silk-lpc-tables.js', '--check'), ('generate-silk-nlsf-tables.js', '--check'), ('generate-silk-indices-tables.js', '--check'), ('generate-silk-parameters-tables.js', '--check'), ('generate-celt-tables.js', '--check'), ('generate-silk-packet-reference.js', '--check')],
          sources=['opus-multistream-oracle.c', '@celt/bands.c', '@celt/cwrs.c', '@celt/entcode.c', '@celt/entdec.c', '@celt/entenc.c', '@celt/kiss_fft.c', '@celt/laplace.c', '@celt/mathops.c', '@celt/mdct.c', '@celt/modes.c', '@celt/pitch.c', '@celt/celt_lpc.c', '@celt/rate.c', '@celt/vq.c', '@src/opus.c', '@src/opus_encoder.c', '@src/repacketizer.c'],
          defines=['OPUS_BUILD', 'USE_ALLOCA', 'SMALL_FOOTPRINT'], includes=['include', 'celt', 'src', 'silk', 'silk/float'], fp='strict', generated=True,
          precise=['@celt/quant_bands.c', 'SILK_SOURCES'], args=[],
          report={'result': 'passed', 'reference': 'RFC6716 + RFC8251 (archive86a927223e73d2476646a1b933fcd3fffb6ecc8c,patch029e3aa88fc342c91e67a21e7bfbc9458661cd5f); Opus1.5.2 self-delimited parser, full opus.c SHA256 f5ae5ff3e9cef998addeee777dcb283cffcaf0f6ee4452108127e9157cdb2458', 'scope': 'Ogg/Opus mapping family1,1..8 logical speaker channels,1..255 elementary streams, full coupled/channel-map bounds, separate histories, RFC7845 stereo downmix, framing/padding, gain/pre-skip/granules/end trim, seek reset and cancellation', 'comparison': 'Generated independent native elementary-stream PCM plus independent double-precision speaker matrices; bounded/canary and immutable-input checks, reset-reference seeking, malformed packed streams/header maps, unmapped entropy/sticky error and cancellation checks', 'scale_adjusted_absolute_tolerance': 4e-05, 'stats': None}),
]


def packet_reference(reference):
    """Extracts the normative packet helpers, keeping the reference license."""
    source = (reference / 'src' / 'opus_decoder.c').read_text(encoding='utf-8')
    header = source[:source.index('#ifdef HAVE_CONFIG_H')] + ('\n#include <stddef.h>\ntypedef int opus_int32;\n'
                                                            '#define OPUS_BAD_ARG -1\n#define OPUS_INVALID_PACKET -4\n')
    first = source.index('int opus_packet_get_samples_per_frame(')
    last = source.index('int opus_packet_get_nb_channels(', first)
    duration = source[first:last].replace('opus_packet_get_samples_per_frame', 'reference_samples_per_frame')
    first = source.index('static int parse_size(')
    last = source.index('int opus_decode_native(', first)
    parser = source[first:last].replace('opus_packet_get_samples_per_frame', 'reference_samples_per_frame') \
        .replace('int opus_packet_parse(', 'int reference_packet_parse(')
    GENERATED_INCLUDE.mkdir(parents=True, exist_ok=True)
    (GENERATED_INCLUDE / 'opus_packet_reference.h').write_text(header + '\n' + duration + '\n' + parser + '\n', encoding='utf-8')


def run_suite(suite, reference, library):
    work = GENERATED / 'opus' / suite.name
    work.mkdir(parents=True, exist_ok=True)
    for generator, mode in suite.tables:
        if mode == 'GENERATED':
            node(generator, reference, work / 'reference_header.c')
        elif mode:
            node(generator, reference, mode)
        else:
            node(generator, reference)
    if suite.name == 'packet':
        packet_reference(reference)
    includes = [reference / i for i in suite.includes]
    if suite.generated:
        includes.append(GENERATED_INCLUDE)
    defines = list(suite.defines)
    if WINDOWS and 'USE_ALLOCA' in defines:
        defines.append('WIN32')

    def resolve(name):
        if name.startswith('@'):
            return reference / name[1:]
        if name.startswith('%'):
            return work / name[1:]
        return TESTS / name
    objects = []
    precise = []
    for name in suite.precise:
        precise += silk_float_sources(reference) if name == 'SILK_SOURCES' else [resolve(name)]
    if precise:
        objects = compile_c(work / 'precise', precise, defines=defines, includes=includes, fp='precise', compile_only=True)
    oracle = compile_c(exe(f'opus-{suite.name}-oracle'), [resolve(s) for s in suite.sources], objects=objects,
                       defines=defines, includes=includes, fp=suite.fp, libraries=[library])
    try:
        result = run([oracle, *[TESTS / a for a in suite.args]])
    except Failure as error:
        raise Failure(f'Assembly {suite.name} mismatch: {error}')
    print(result)
    report = dict(suite.report)
    report['stats'] = result
    write_report(f'opus-{suite.name}', report)


def main():
    selected = sys.argv[1:]
    unknown = set(selected) - {s.name for s in SUITES}
    if unknown:
        raise Failure('Unknown suite: ' + ', '.join(sorted(unknown)))
    reference = opus_reference()
    library = build_lamp()
    node('generate-celt-tables.js', reference, '--check')
    for suite in SUITES:
        if not selected or suite.name in selected:
            print(f'== opus {suite.name}', flush=True)
            run_suite(suite, reference, library)
    if not selected:
        print('All thirty-five Opus suites passed, using the RFC8251-updated PCM reference and test-only '
              'Opus1.5.2 self-delimited framing reference; packet-to-PCM, Ogg families0/1, stereo downmix, '
              'gain/pre-skip/end trimming/seeking, SILK/hybrid/CELT transitions, FEC, DTX and loss/recovery. '
              'Run verify-opus-conformance.py separately for official vectors.')


if __name__ == '__main__':
    main_guard(main)
