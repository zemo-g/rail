#!/usr/bin/env python3
"""
tools/garmin/usb_probe.py - read-only probe of the Garmin USB protocol.

Watch must be in `Settings > System > USB Mode > Garmin`. This script
issues:

  - Pid_Start_Session (USB layer, PID 5)
  - Pid_Product_Rqst (Application layer, PID 254)
  - For each transfer protocol the device reports it supports, OPTIONALLY
    a Cmnd_Transfer_* on the safe verbs only.

Strict read-only. Never sends a command that writes flash, erases, or
factory-resets. PIDs sent are explicitly enumerated below.
"""
import struct
import sys
import time
import usb.core, usb.util

VID = 0x091E
PID_GARMIN_PROT = 0x0003  # vendor-specific protocol, set when USB Mode = Garmin

# Layer types
TYPE_USB_PROTOCOL = 0x00
TYPE_APP_LAYER    = 0x14

# USB Protocol Layer PIDs (low ones)
PID_DATA_AVAILABLE   = 2
PID_START_SESSION    = 5
PID_SESSION_STARTED  = 6

# Application Layer PIDs (subset; full list in pygarmin/link.py)
PID_PROTOCOL_ARRAY   = 253
PID_PRODUCT_RQST     = 254
PID_PRODUCT_DATA     = 255
PID_EXT_PRODUCT_DATA = 248
PID_RECORDS          = 27
PID_RGN_DATA         = 50
PID_RGN_HEADER       = 51
PID_PVT_DATA         = 51   # different layer, but same byte; context-dependent

def pack_packet(layer, pid, data=b""):
    return struct.pack("<BBBBHHI", layer, 0, 0, 0, pid, 0, len(data)) + data

def parse_header(buf):
    if len(buf) < 12: return None
    layer, _, _, _, pid, _resv, size = struct.unpack("<BBBBHHI", buf[:12])
    return layer, pid, size, buf[12:12+size]

def find_dev():
    dev = usb.core.find(idVendor=VID, idProduct=PID_GARMIN_PROT)
    if dev is None:
        # Maybe still in MSC mode?
        any_garmin = usb.core.find(idVendor=VID)
        if any_garmin is None:
            print("No Garmin device on USB at all.")
        else:
            print(f"Garmin device present but with idProduct=0x{any_garmin.idProduct:04x}, not 0x{PID_GARMIN_PROT:04x}.")
            print(f"Set Settings > System > USB Mode > Garmin on the watch and re-plug.")
        sys.exit(1)
    return dev

def main():
    dev = find_dev()
    cfg = dev.get_active_configuration()
    intf = cfg[(0, 0)]

    # Find the three endpoints
    bulk_in   = usb.util.find_descriptor(intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress)==usb.util.ENDPOINT_IN
        and usb.util.endpoint_type(e.bmAttributes)==usb.util.ENDPOINT_TYPE_BULK)
    bulk_out  = usb.util.find_descriptor(intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress)==usb.util.ENDPOINT_OUT
        and usb.util.endpoint_type(e.bmAttributes)==usb.util.ENDPOINT_TYPE_BULK)
    intr_in   = usb.util.find_descriptor(intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress)==usb.util.ENDPOINT_IN
        and usb.util.endpoint_type(e.bmAttributes)==usb.util.ENDPOINT_TYPE_INTR)
    print(f"endpoints: bulk_in=0x{bulk_in.bEndpointAddress:02x} "
          f"bulk_out=0x{bulk_out.bEndpointAddress:02x} "
          f"intr_in=0x{intr_in.bEndpointAddress:02x}")

    usb.util.claim_interface(dev, 0)

    def read_one(timeout_ms=500, source="intr"):
        ep = intr_in if source=="intr" else bulk_in
        try:
            data = bytes(dev.read(ep.bEndpointAddress, 4096, timeout=timeout_ms))
            return data
        except usb.core.USBTimeoutError:
            return None

    def send(layer, pid, data=b"", quiet=False):
        pkt = pack_packet(layer, pid, data)
        if not quiet:
            print(f"  --> layer=0x{layer:02x} pid={pid} size={len(data)}: {pkt.hex()}")
        dev.write(bulk_out.bEndpointAddress, pkt, timeout=1000)

    # 1) Start Session
    print("\n[1] Pid_Start_Session")
    send(TYPE_USB_PROTOCOL, PID_START_SESSION)
    # 2) Drain replies on intr until we see Pid_Session_Started
    print("[2] reading interrupt for Pid_Session_Started ...")
    started = None
    for _ in range(20):
        b = read_one(source="intr", timeout_ms=500)
        if b is None: continue
        h = parse_header(b)
        if h is None: continue
        layer, pid, size, payload = h
        print(f"  <-- intr layer=0x{layer:02x} pid={pid} size={size}: payload={payload.hex()}")
        if layer == TYPE_USB_PROTOCOL and pid == PID_SESSION_STARTED:
            started = payload
            break
    if started is None:
        print("ERROR: no Pid_Session_Started seen.")
        usb.util.release_interface(dev, 0)
        return 1

    # 3) Pid_Product_Rqst
    print("\n[3] Pid_Product_Rqst")
    send(TYPE_APP_LAYER, PID_PRODUCT_RQST)

    # 4) Drain - device may send multiple Pid_Data_Available bursts.
    print("[4] reading replies (intr + bulk; quit after 4s of silence)")
    deadline = time.time() + 6.0
    last_event = time.time()
    while time.time() < deadline:
        if time.time() - last_event > 4.0:
            break
        b = read_one(source="intr", timeout_ms=200)
        if b is None: continue
        last_event = time.time()
        h = parse_header(b)
        if h is None:
            print(f"  raw intr: {b.hex()}"); continue
        layer, pid, size, payload = h
        print(f"  <-- intr layer=0x{layer:02x} pid={pid} size={size}: payload={payload.hex()}")
        if layer == TYPE_USB_PROTOCOL and pid == PID_DATA_AVAILABLE:
            print("    Pid_Data_Available - draining bulk:")
            for _ in range(50):  # cap so we never hang here
                bd = read_one(source="bulk", timeout_ms=500)
                if bd is None or len(bd) == 0:
                    break
                last_event = time.time()
                hd = parse_header(bd)
                if hd is None:
                    print(f"      bulk raw: {bd.hex()}"); continue
                blayer, bpid, bsize, bpayload = hd
                print(f"    <-- bulk layer=0x{blayer:02x} pid={bpid} size={bsize}: payload={bpayload.hex()}")
                if blayer == TYPE_APP_LAYER and bpid == PID_PRODUCT_DATA and len(bpayload) >= 4:
                    prod_id, sw_ver = struct.unpack("<HH", bpayload[:4])
                    rest = bpayload[4:]
                    strs = []
                    while rest:
                        i = rest.find(b'\x00')
                        if i < 0:
                            strs.append(rest.decode('latin-1','replace')); break
                        strs.append(rest[:i].decode('latin-1','replace'))
                        rest = rest[i+1:]
                    print(f"    *** PRODUCT DATA: product_id=0x{prod_id:04x} ({prod_id})")
                    print(f"        sw_version={sw_ver/100:.2f}  (raw {sw_ver})")
                    print(f"        strings={strs}")
                elif blayer == TYPE_APP_LAYER and bpid == PID_EXT_PRODUCT_DATA:
                    s = bpayload.split(b'\x00')[0].decode('latin-1','replace')
                    print(f"    *** EXT PRODUCT DATA: {s!r}  (e.g. GPS chip firmware)")
                elif blayer == TYPE_APP_LAYER and bpid == PID_PROTOCOL_ARRAY:
                    arr = bpayload
                    items = []
                    for i in range(0, len(arr) - 2, 3):
                        tag = chr(arr[i])
                        nb = struct.unpack('<H', arr[i+1:i+3])[0]
                        items.append(f"{tag}{nb:03d}")
                    print(f"    *** PROTOCOL ARRAY ({len(items)} entries): {' '.join(items)}")
    print("\n(done draining)")
    usb.util.release_interface(dev, 0)
    return 0

if __name__ == "__main__":
    sys.exit(main())
