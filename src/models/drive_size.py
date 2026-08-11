def drive_size_mb_to_bytes(value):
    """Convert a user-entered decimal MB value into bytes."""
    if value is None:
        raise ValueError("Max drive size is required.")

    if isinstance(value, str):
        value = value.strip()
        if not value:
            raise ValueError("Max drive size is required.")
        value = value.lower().replace(" ", "")
        if value.endswith("mb"):
            value = value[:-2]
        elif value.endswith("m"):
            value = value[:-1]

    try:
        size_mb = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Invalid max drive size: {value!r}") from exc

    if size_mb <= 0:
        raise ValueError("Max drive size must be greater than zero.")

    return int(size_mb * 1_000_000)


def drive_size_bytes_to_mb(value):
    """Return decimal MB for display from a byte count."""
    size_bytes = int(value)
    size_mb = size_bytes / 1_000_000
    return int(size_mb) if size_mb.is_integer() else round(size_mb, 2)


def resolve_max_drive_size(config, settings=None):
    """
    Resolve per-run drive capacity.

    UI/settings can provide either:
    - max_drive_size_mb: human-entered decimal MB, e.g. 480
    - max_drive_size: raw bytes, retained for programmatic callers
    """
    settings = settings or {}

    max_drive_size_mb = settings.get("max_drive_size_mb")
    if max_drive_size_mb not in (None, ""):
        return drive_size_mb_to_bytes(max_drive_size_mb)

    max_drive_size = settings.get("max_drive_size")
    if max_drive_size not in (None, ""):
        return int(max_drive_size)

    return int(config.params["max_drive_size"])
