"""Local GigaAM CLI. No backend imports or global environment changes."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import wave

ROOT = Path(__file__).resolve().parent


def configure_ffmpeg():
    if shutil.which('ffmpeg'):
        return 'ffmpeg'
    import imageio_ffmpeg
    source = Path(imageio_ffmpeg.get_ffmpeg_exe())
    tools = ROOT / 'tools'
    tools.mkdir(exist_ok=True)
    target = tools / ('ffmpeg.exe' if os.name == 'nt' else 'ffmpeg')
    if not target.exists():
        shutil.copy2(source, target)
    os.environ['PATH'] = str(tools) + os.pathsep + os.environ.get('PATH', '')
    return str(target)


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description='GigaAM v3 Russian transcription')
    parser.add_argument('--input', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--device', choices=['cuda', 'cpu'], default='cuda')
    parser.add_argument('--batch-size', type=int, default=1)
    parser.add_argument('--repeat', type=int, default=1, help='Measured runs with one loaded model')
    args = parser.parse_args()
    args.input = args.input.resolve()
    args.output = args.output.resolve()
    total_started = time.perf_counter()
    try:
        if not args.input.is_file():
            raise ValueError(f'Audio file not found: {args.input}')
        if args.input.resolve() == args.output.resolve():
            raise ValueError('Input and output must be different files')
        if args.repeat < 1 or args.batch_size < 1:
            raise ValueError('repeat and batch-size must be positive')
        ffmpeg = configure_ffmpeg()
        os.environ.setdefault('HF_HOME', str(ROOT / '.cache' / 'huggingface'))
        import torch
        import gigaam
        if args.device == 'cuda' and not torch.cuda.is_available():
            raise ValueError('CUDA is unavailable. Install CUDA PyTorch or use --device cpu.')
        def sync():
            if args.device == 'cuda':
                torch.cuda.synchronize()
        with tempfile.TemporaryDirectory(prefix='gigaam-') as folder:
            wav = Path(folder) / 'input.wav'
            decode_started = time.perf_counter()
            decoded = subprocess.run([ffmpeg, '-nostdin', '-v', 'error', '-i',
                str(args.input.resolve()), '-ac', '1', '-ar', '16000', '-c:a',
                'pcm_s16le', str(wav)], capture_output=True, text=True, errors='replace')
            if decoded.returncode:
                raise ValueError('Unsupported or damaged audio: ' + decoded.stderr[-1500:])
            decode_seconds = time.perf_counter() - decode_started
            with wave.open(str(wav), 'rb') as audio:
                duration = audio.getnframes() / audio.getframerate()
            if duration <= 0:
                raise ValueError('Audio is empty')
            longform = duration > 25
            if longform and not os.environ.get('HF_TOKEN'):
                raise ValueError('Long audio requires official pyannote VAD: accept '
                    'pyannote/segmentation-3.0 conditions and set HF_TOKEN locally; '
                    'install the longform extra. Do not send tokens in chat.')
            if args.device == 'cuda':
                torch.cuda.reset_peak_memory_stats()
            sync()
            started = time.perf_counter()
            # SentencePiece on Windows fails on Cyrillic absolute model paths.
            # This standalone CLI uses an ASCII relative tokenizer path instead.
            os.chdir(ROOT)
            model = gigaam.load_model('v3_e2e_rnnt', device=args.device,
                download_root='models', use_flash=False)
            sync()
            load_seconds = time.perf_counter() - started
            runs = []
            for _ in range(args.repeat):
                sync()
                started = time.perf_counter()
                result = (model.transcribe_longform(str(wav), fr_batch_size=args.batch_size)
                          if longform else model.transcribe(str(wav)))
                sync()
                elapsed = time.perf_counter() - started
                text = result.text
                runs.append({'seconds': elapsed, 'rtf': elapsed / duration})
            metrics = {'model': 'v3_e2e_rnnt', 'audio_seconds': duration,
                'decode_seconds': decode_seconds, 'load_seconds': load_seconds,
                'runs': runs, 'longform': longform,
                'total_seconds_before_save': time.perf_counter() - total_started,
                'device': args.device, 'torch': torch.__version__, 'cuda': torch.version.cuda,
                'gpu': torch.cuda.get_device_name() if args.device == 'cuda' else None,
                'peak_allocated_mib': torch.cuda.max_memory_allocated()/2**20 if args.device == 'cuda' else None,
                'peak_reserved_mib': torch.cuda.max_memory_reserved()/2**20 if args.device == 'cuda' else None}
            args.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = args.output.with_suffix(args.output.suffix + '.tmp')
            temporary.write_text(text + '\n', encoding='utf-8')
            temporary.replace(args.output)
            if longform:
                args.output.with_suffix(args.output.suffix + '.segments.json').write_text(
                    json.dumps([{'start': s.start, 'end': s.end, 'text': s.text}
                                for s in result], ensure_ascii=False, indent=2), encoding='utf-8')
            args.output.with_suffix(args.output.suffix + '.metrics.json').write_text(
                json.dumps(metrics, ensure_ascii=False, indent=2), encoding='utf-8')
            print(text)
            print(json.dumps(metrics, ensure_ascii=False, indent=2))
        return 0
    except KeyboardInterrupt:
        print('Cancelled. No new completed transcript was saved.', file=sys.stderr)
        return 130
    except Exception as exc:
        print(f'Error: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
