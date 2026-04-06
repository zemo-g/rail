#!/usr/bin/env python3
"""Visualize MHD simulation frames from Rail plasma simulator."""
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.colors as colors
from pathlib import Path
import sys

N = 128

def load_frame(path):
    """Load a density field from space-separated text file."""
    data = np.loadtxt(path)
    return data.reshape(N, N)

def plot_frame(data, title="", save_path=None):
    """Plot a single density field."""
    fig, ax = plt.subplots(1, 1, figsize=(10, 4))
    im = ax.imshow(data, cmap='inferno', origin='lower',
                   extent=[0, 2*np.pi, 0, 2*np.pi], aspect='auto')
    plt.colorbar(im, ax=ax, label='Density (ρ)')
    ax.set_xlabel('x')
    ax.set_ylabel('y')
    ax.set_title(title or 'Orszag-Tang Vortex — Density')
    plt.tight_layout()
    if save_path:
        plt.savefig(save_path, dpi=150)
        print(f"Saved: {save_path}")
    plt.close()

def plot_all_frames():
    """Plot all available frames as a grid."""
    frames = sorted(Path('/tmp').glob('mhd_frame_*.dat'))
    if not frames:
        print("No frames found in /tmp/mhd_frame_*.dat")
        return

    n = len(frames)
    print(f"Found {n} frames")

    if n == 1:
        data = load_frame(frames[0])
        plot_frame(data, f"Orszag-Tang Vortex — {frames[0].stem}",
                   '/tmp/mhd_plasma.png')
        return

    cols = min(n, 4)
    rows = (n + cols - 1) // cols
    fig, axes = plt.subplots(rows, cols, figsize=(4*cols, 3.5*rows))
    if rows == 1:
        axes = [axes] if cols == 1 else axes
    else:
        axes = axes.flatten()

    vmin = min(load_frame(f).min() for f in frames)
    vmax = max(load_frame(f).max() for f in frames)

    for i, fpath in enumerate(frames):
        data = load_frame(fpath)
        ax = axes[i] if n > 1 else axes
        im = ax.imshow(data, cmap='inferno', origin='lower',
                       extent=[0, 2*np.pi, 0, 2*np.pi], aspect='auto',
                       vmin=vmin, vmax=vmax)
        ax.set_title(fpath.stem.replace('mhd_frame_', 'frame '), fontsize=10)
        ax.set_xticks([0, np.pi, 2*np.pi])
        ax.set_xticklabels(['0', 'π', '2π'])
        ax.set_yticks([0, np.pi, 2*np.pi])
        ax.set_yticklabels(['0', 'π', '2π'])

    # Hide unused axes
    for i in range(n, len(axes)):
        axes[i].set_visible(False)

    fig.suptitle('RAIL PLASMA — Orszag-Tang Vortex (density)', fontsize=14, fontweight='bold')
    plt.tight_layout()
    plt.savefig('/tmp/mhd_plasma.png', dpi=150)
    print(f"Saved: /tmp/mhd_plasma.png")
    plt.close()

if __name__ == '__main__':
    plot_all_frames()
