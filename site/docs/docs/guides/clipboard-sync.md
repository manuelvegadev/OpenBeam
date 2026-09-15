# Clipboard sync

Clipboard sync copies what you cut or copy on one machine to the clipboard of another.
It is off until you turn it on, and it only ever talks to devices you have paired by
hand.

## Pair two machines

1. Open **Settings → Clipboard** on both machines.
2. Turn on **Sync the clipboard**.
3. Each machine lists the other under **Discovered**. Click **Pair**.
4. The other machine shows a request. Accept it there.

Once paired, the devices appear under **Paired** and the clipboard follows you between
them.

## Forget a device

Click **Forget** next to it. OpenBeam asks first, because forgetting is not one-sided in
effect: you have to pair again from both ends to resume syncing.

## What travels

Discovery uses Bonjour on the local network, and the connection between two paired
devices is encrypted and authenticated with keys exchanged during pairing. A device that
has not been paired cannot read anything, and pairing cannot be completed from one side
alone.
