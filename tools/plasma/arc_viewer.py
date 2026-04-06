#!/usr/bin/env python3
"""Live viewer for arc discharge simulation."""
import numpy as np
import matplotlib
matplotlib.use('macosx')
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from pathlib import Path

NX, NY = 256, 64
FRAME_DIR = Path('/tmp/mhd_arc')

# Also generate a static snapshot for quick viewing
def quick_snapshot():
    frames = get_frames()
    if not frames:
        print("No frames found")
        return
    n = len(frames)
    # Pick 4 evenly spaced frames
    picks = [0, n//3, 2*n//3, n-1]
    fig, axes = plt.subplots(4, 1, figsize=(14, 8))
    fig.patch.set_facecolor('black')
    for i, pi in enumerate(picks):
        data = load_frame(frames[pi])
        if data is None:
            continue
        ax = axes[i]
        ax.set_facecolor('black')
        im = ax.imshow(data, cmap='plasma', origin='lower',
                       extent=[0, 4, 0, 1], aspect='auto',
                       interpolation='bilinear')
        ax.set_ylabel(f'f{pi}', color='white', fontsize=9)
        ax.tick_params(colors='white', labelsize=8)
        if i == 0:
            ax.set_title('RAIL PLASMA — Arc in Magnetic Field (By=0.5)', color='white',
                         fontsize=13, fontweight='bold')
    plt.tight_layout()
    plt.savefig('/tmp/rail_arc.png', dpi=150, facecolor='black')
    print("Saved: /tmp/rail_arc.png")
    plt.close()

def load_frame(path):
    try:
        return np.loadtxt(path).reshape(NY, NX)
    except Exception:
        return None

def get_frames():
    return sorted(FRAME_DIR.glob('frame_*.dat'))

def viewer():
    import time
    print("Waiting for frames in /tmp/mhd_arc/ ...")
    while not get_frames():
        time.sleep(0.5)

    frames = get_frames()
    data = load_frame(frames[0])

    fig, ax = plt.subplots(1, 1, figsize=(14, 4))
    fig.patch.set_facecolor('black')
    ax.set_facecolor('black')

    im = ax.imshow(data, cmap='plasma', origin='lower',
                   extent=[0, 4, 0, 1], aspect='auto',
                   interpolation='bilinear')
    cbar = plt.colorbar(im, ax=ax, label='Density', fraction=0.015, pad=0.02)
    cbar.ax.yaxis.label.set_color('white')
    cbar.ax.tick_params(colors='white')

    # Draw electrode markers
    ax.axvline(x=0.2, color='cyan', linewidth=2, alpha=0.5, linestyle='--')
    ax.axvline(x=3.8, color='red', linewidth=2, alpha=0.5, linestyle='--')

    # Draw magnet positions
    ax.plot(2.0, -0.3 * (1/4), 'v', color='lime', markersize=12, clip_on=False)
    ax.plot(2.0, 1 + 0.3 * (1/4), '^', color='lime', markersize=12, clip_on=False)

    ax.set_title('RAIL PLASMA — Arc Discharge with Magnetic Pinch', color='white',
                 fontsize=14, fontweight='bold')
    info = ax.text(0.5, -0.15, '', transform=ax.transAxes, ha='center',
                   color='#aaa', fontsize=10)
    ax.set_xlabel('Tube length', color='white')
    ax.set_ylabel('', color='white')
    ax.tick_params(colors='white')

    state = {'idx': 0, 'paused': False, 'cache': {}}

    def update(frame_num):
        frames = get_frames()
        n = len(frames)
        if not state['paused']:
            state['idx'] = min(state['idx'] + 1, n - 1)

        if state['idx'] < n:
            path = frames[state['idx']]
            if path not in state['cache']:
                d = load_frame(path)
                if d is not None:
                    state['cache'][path] = d
            d = state['cache'].get(path)
            if d is not None:
                im.set_data(d)
                im.set_clim(d.min(), d.max())
                info.set_text(f'frame {state["idx"]}/{n}  '
                             f'ρ=[{d.min():.2f}, {d.max():.2f}]')
        return [im, info]

    def on_key(event):
        if event.key == ' ':
            state['paused'] = not state['paused']
        elif event.key == 'left':
            state['idx'] = max(0, state['idx'] - 1)
            state['paused'] = True
        elif event.key == 'right':
            state['idx'] += 1
            state['paused'] = True
        elif event.key == 's':
            save_gif()
        elif event.key in ('q', 'escape'):
            plt.close()

    def save_gif():
        frames = get_frames()
        all_data = [load_frame(f) for f in frames]
        all_data = [d for d in all_data if d is not None]
        if not all_data:
            return
        print(f"Saving GIF ({len(all_data)} frames)...")
        fig2, ax2 = plt.subplots(1, 1, figsize=(14, 4))
        fig2.patch.set_facecolor('black')
        ax2.set_facecolor('black')
        vmin = min(d.min() for d in all_data)
        vmax = max(d.max() for d in all_data)
        im2 = ax2.imshow(all_data[0], cmap='plasma', origin='lower',
                         extent=[0, 4, 0, 1], aspect='auto',
                         interpolation='bilinear', vmin=vmin, vmax=vmax)
        plt.colorbar(im2, ax=ax2, fraction=0.015)
        ax2.set_title('RAIL PLASMA — Arc Discharge', color='white', fontsize=14)
        ax2.tick_params(colors='white')

        def gif_update(i):
            im2.set_data(all_data[i])
            return [im2]

        ani = animation.FuncAnimation(fig2, gif_update, frames=len(all_data),
                                       interval=60, blit=True)
        ani.save('/tmp/rail_arc.gif', writer='pillow', fps=15)
        print("Saved: /tmp/rail_arc.gif")
        plt.close(fig2)

    fig.canvas.mpl_connect('key_press_event', on_key)
    ani = animation.FuncAnimation(fig, update, interval=80, blit=True, cache_frame_data=False)
    plt.tight_layout()
    plt.show()

if __name__ == '__main__':
    import sys
    if '--snapshot' in sys.argv:
        quick_snapshot()
    else:
        viewer()
