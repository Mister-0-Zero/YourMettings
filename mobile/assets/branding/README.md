# YourMettings launcher icon

Emerald background, ivory speech bubble and five audio bars. No lettering. The central mark stays inside the Android adaptive icon safe region. Legacy and adaptive Android resources replace the Flutter placeholder; iOS AppIcon source resources use the same master, but iOS has not been built on Windows.

Master: yourmettings-icon-master.png. Generated with the built-in image_gen tool on 2026-10-22. Kept in the project; no runtime network/image-generation dependency.

Repackage without changing the design: `python scripts/generate_launcher_icons.py` from mobile/ (requires Pillow). Only lossless PNG packaging and density resizing are performed. The master is opaque; iOS outputs are RGB without alpha.

Generation prompt:

> Use case: logo-brand. Create a polished production-ready launcher icon master for the Android app YourMettings, an assistant for recording meetings and turning speech into notes. A single bold flat geometric ivory symbol combining a speech bubble / small note with a five-bar sound waveform, on a solid deep emerald green square background (#185D48). Friendly rounded geometry, restrained professional productivity-app style, high contrast, no lettering, no words, no checkmark, no gradients, no shadows, no mockup, no device, no border. Artwork centered and recognizable at 48 pixels. Keep the entire main symbol comfortably inside the central 60% of the square so circular and squircle launcher masks never clip it. Background fills every edge, square output.
