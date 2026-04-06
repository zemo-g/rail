#!/usr/bin/env python3
"""Live MHD plasma viewer — watches for new frames, animates in real-time.

Usage:
  # Terminal 1: run the sim
  cd ~/projects/rail && ./rail_native run tools/plasma/mhd.rail

  # Terminal 2: watch it live
  python3 tools/plasma/live.py

  # Or replay after sim finishes:
  python3 tools/plasma/live.py --replay

Controls:
  SPACE  — pause/resume
  LEFT   — previous frame
  RIGHT  — next frame
  UP     — speed up
  DOWN   — slow down
  S      — save as GIF
  Q/ESC  — quit
"""
import numpy as np
import matplotlib
matplotlib.use('macosx')
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from pathlib import Path
import time
import sys

N = 128
FRAME_DIR = Path('/tmp/mhd_live')
FPS = 12

def load_frame(path):
    try:
        return np.loadtxt(path).reshape(N, N)
    except Exception:
        return None

def get_frames():
    return sorted(FRAME_DIR.glob('frame_*.dat'))

def live_viewer():
    """Real-time viewer that polls for new frames."""
    fig, ax = plt.subplots(1, 1, figsize=(8, 4))
    fig.patch.set_facecolor('black')
    ax.set_facecolor('black')

    # Wait for first frame
    print("Waiting for frames in /tmp/mhd_live/ ...")
    while not get_frames():
        time.sleep(0.5)

    frames = get_frames()
    data = load_frame(frames[0])
    im = ax.imshow(data, cmap='inferno', origin='lower',
                   extent=[0, 2*np.pi, 0, 2*np.pi], aspect='auto',
                   interpolation='bilinear')
    cbar = plt.colorbar(im, ax=ax, label='Density (ρ)', fraction=0.025)
    cbar.ax.yaxis.label.set_color('white')
    cbar.ax.tick_params(colors='white')
    title = ax.set_title('RAIL PLASMA — Orszag-Tang Vortex', color='white',
                         fontsize=14, fontweight='bold')
    subtitle = ax.text(0.5, 1.02, 'frame 0', transform=ax.transAxes,
                       ha='center', color='#aaa', fontsize=10)
    ax.set_xlabel('x', color='white')
    ax.set_ylabel('y', color='white')
    ax.tick_params(colors='white')

    state = {
        'idx': 0,
        'paused': False,
        'speed': 1.0,
        'frames_cache': {},
        'vmin': data.min(),
        'vmax': data.max(),
    }

    def get_frame_data(i):
        frames = get_frames()
        if i >= len(frames):
            return None
        path = frames[i]
        if path not in state['frames_cache']:
            d = load_frame(path)
            if d is not None:
                state['frames_cache'][path] = d
        return state['frames_cache'].get(path)

    def update(frame_num):
        frames = get_frames()
        n_frames = len(frames)

        if not state['paused']:
            state['idx'] += 1
            if state['idx'] >= n_frames:
                state['idx'] = n_frames - 1
                # Check for new frames
                new_frames = get_frames()
                if len(new_frames) > n_frames:
                    state['idx'] = n_frames  # advance to new frame

        data = get_frame_data(state['idx'])
        if data is not None:
            # Auto-adjust color range
            state['vmin'] = min(state['vmin'], data.min())
            state['vmax'] = max(state['vmax'], data.max())
            im.set_data(data)
            im.set_clim(state['vmin'], state['vmax'])
            t_est = state['idx'] * 15 * 0.0038  # rough time estimate
            subtitle.set_text(f'frame {state["idx"]}/{n_frames}  t≈{t_est:.2f}  '
                            f'ρ=[{data.min():.2f}, {data.max():.2f}]')
        return [im, subtitle]

    def on_key(event):
        if event.key == ' ':
            state['paused'] = not state['paused']
            print(f"{'Paused' if state['paused'] else 'Playing'}")
        elif event.key == 'left':
            state['idx'] = max(0, state['idx'] - 1)
            state['paused'] = True
        elif event.key == 'right':
            state['idx'] += 1
            state['paused'] = True
        elif event.key == 'up':
            state['speed'] = min(4.0, state['speed'] * 1.5)
            print(f"Speed: {state['speed']:.1f}x")
        elif event.key == 'down':
            state['speed'] = max(0.25, state['speed'] / 1.5)
            print(f"Speed: {state['speed']:.1f}x")
        elif event.key == 's':
            save_gif()
        elif event.key in ('q', 'escape'):
            plt.close()

    def save_gif():
        frames = get_frames()
        print(f"Saving GIF with {len(frames)} frames...")
        fig2, ax2 = plt.subplots(1, 1, figsize=(8, 4))
        fig2.patch.set_facecolor('black')
        ax2.set_facecolor('black')

        all_data = [load_frame(f) for f in frames]
        all_data = [d for d in all_data if d is not None]
        vmin = min(d.min() for d in all_data)
        vmax = max(d.max() for d in all_data)

        im2 = ax2.imshow(all_data[0], cmap='inferno', origin='lower',
                         extent=[0, 2*np.pi, 0, 2*np.pi], aspect='auto',
                         interpolation='bilinear', vmin=vmin, vmax=vmax)
        plt.colorbar(im2, ax=ax2, label='Density', fraction=0.025)
        ttl = ax2.set_title('RAIL PLASMA — Orszag-Tang Vortex', color='white',
                            fontsize=14, fontweight='bold')
        ax2.tick_params(colors='white')
        ax2.set_xlabel('x', color='white')
        ax2.set_ylabel('y', color='white')

        def gif_update(i):
            im2.set_data(all_data[i])
            return [im2]

        ani = animation.FuncAnimation(fig2, gif_update, frames=len(all_data),
                                       interval=80, blit=True)
        out = '/tmp/rail_plasma.gif'
        ani.save(out, writer='pillow', fps=12)
        print(f"Saved: {out}")
        plt.close(fig2)

    fig.canvas.mpl_connect('key_press_event', on_key)
    interval = max(20, int(1000 / FPS))
    ani = animation.FuncAnimation(fig, update, interval=interval, blit=True, cache_frame_data=False)
    plt.tight_layout()
    plt.show()

if __name__ == '__main__':
    live_viewer()
