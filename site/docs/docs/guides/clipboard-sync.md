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

## What syncs

Text, images and files.

Copy a screenshot — from Shottr, from <kbd>⌘⇧4</kbd>, from a browser — and it pastes as a
picture on the other machine, without ever becoming a file you have to find. Copy files in
the Finder and they arrive on the other clipboard as files.

**Settings → Clipboard** has a switch for images and another for files, so you can keep
text-only syncing if that is all you want, and two size limits: text over the limit is left
alone rather than sent, and an image or transfer over it is refused in either direction.

When something you copy is both a picture and text — an image copied from a web page leaves
its address on the clipboard beside it — the picture is what travels.

## Forget a device

Click **Forget** next to it. OpenBeam asks first, because forgetting is not one-sided in
effect: you have to pair again from both ends to resume syncing.

## What travels

Discovery uses Bonjour on the local network, and the connection between two paired
devices is encrypted and authenticated with keys exchanged during pairing. A device that
has not been paired cannot read anything, and pairing cannot be completed from one side
alone.
