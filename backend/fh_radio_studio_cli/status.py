from __future__ import annotations

from .baseline import baseline_version_id
from .common import *
from .external_tools import collect_tool_status
from .game import (
    default_radio_info,
    effective_audio_dir_for,
    find_station,
    game_root_for,
    is_forza_running,
    parse_xml,
    resolve_game_dir,
    station_summary,
    steam_game_version,
)
from .language import (
    normalize_text_language,
    read_user_preferred_lang,
    resolve_user_preferred_lang_path,
)


def build_status_payload(args: argparse.Namespace) -> Dict[str, object]:
    resolved_game_dir = resolve_game_dir(args.game_dir)
    game_dir = game_root_for(resolved_game_dir)
    audio_dir = effective_audio_dir_for(resolved_game_dir)
    game_version = steam_game_version(game_dir)
    radio_info = default_radio_info(audio_dir)

    root = parse_xml(radio_info).getroot()
    stations_parent = root.find("RadioStations")
    if stations_parent is None:
        die(f"No RadioStations in {radio_info}")

    station_elements = stations_parent.findall("RadioStation")
    radios = [station_summary(station, audio_dir) for station in station_elements]
    selected_radio = (
        station_summary(find_station(root, args.radio), audio_dir)
        if args.radio
        else (radios[0] if radios else None)
    )

    tools, tools_ok = collect_tool_status()
    preferred_path = resolve_user_preferred_lang_path(getattr(args, "preferred_path", None))
    audio_preferred_path = preferred_path.with_name("UserPreferredAudioLang")
    display_preferred = read_user_preferred_lang(preferred_path)
    preferred_lang = read_user_preferred_lang(audio_preferred_path)

    # Read the two game settings independently. Never copy language archives or
    # change the game's preferences as part of status/backup/deployment.
    def detected(value, fallback):
        normalized = normalize_text_language(value or "")
        return (
            normalized if normalized and normalized != "AUTO" else normalize_text_language(fallback)
        )

    source_lang = detected(display_preferred, args.source or "CHS")
    target_lang = detected(preferred_lang, args.target or "JP")
    string_dir = game_dir / "media" / "Stripped" / "StringTables"
    source_path = string_dir / f"{source_lang}.zip"
    target_path = string_dir / f"{target_lang}.zip"
    available_languages = sorted({p.stem.upper() for p in string_dir.glob("*.zip")}) or [
        "CHS",
        "CHT",
        "JP",
        "EN",
        "DE",
        "FR",
        "ES",
        "MX",
        "IT",
        "KO",
        "PL",
        "PT",
        "BR",
        "RU",
    ]
    source_sha = target_sha = source_md5 = target_md5 = None
    source_baseline = target_baseline = {"status": "not_required", "verified": True}
    display_detection, baseline_manifest = (
        "game_preference" if display_preferred else "fallback"
    ), None

    return {
        "schema_version": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "requested_game_dir": str(resolved_game_dir),
        "game_dir": str(game_dir),
        "game_version": game_version,
        "game_version_id": baseline_version_id(game_version),
        "audio_dir": str(audio_dir),
        "radio_info": str(radio_info),
        "game_running": is_forza_running(),
        "tools": tools,
        "tools_ok": tools_ok,
        "preferred_lang_path": str(preferred_path),
        "preferred_lang": preferred_lang,
        "preferred_audio_lang_path": str(audio_preferred_path),
        "language": {
            "string_tables_dir": str(string_dir),
            "source_lang": source_lang,
            "target_lang": target_lang,
            "source_path": str(source_path),
            "target_path": str(target_path),
            "source_exists": True,
            "target_exists": True,
            "source_sha256": source_sha,
            "target_sha256": target_sha,
            "source_md5": source_md5,
            "target_md5": target_md5,
            "target_matches_source": True,
            "available": available_languages,
            "display_detection": display_detection,
            "preferred_lang_effective": target_lang,
            "preferred_lang_source": "game_preference" if preferred_lang else "fallback",
            "source_was_adjusted": (
                normalize_text_language(args.source) != source_lang if args.source else False
            ),
            "target_was_adjusted": (
                normalize_text_language(args.target) != target_lang if args.target else False
            ),
            "baseline_manifest": str(baseline_manifest.resolve()) if baseline_manifest else None,
            "source_baseline": source_baseline,
            "target_baseline": target_baseline,
            "voice_slot_verified": bool(target_baseline.get("verified")),
        },
        "radios": radios,
        "selected_radio": selected_radio,
    }


def cmd_status(args: argparse.Namespace) -> int:
    payload = build_status_payload(args)
    if args.json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    language = payload["language"]
    selected = payload.get("selected_radio") or {}
    playlists = selected.get("playlists", {}) if isinstance(selected, dict) else {}
    preferred = payload.get("preferred_lang") or "<missing>"
    print("Dashboard status:")
    print(f"Game dir       : {payload['game_dir']}")
    print(f"Audio dir      : {payload['audio_dir']}")
    print(f"Game process   : {'running' if payload['game_running'] else 'not running'}")
    print(f"Tools          : {'ok' if payload['tools_ok'] else 'missing'}")
    if isinstance(language, dict):
        source = language.get("source_lang")
        target = language.get("target_lang")
        synced = "synced" if language.get("target_matches_source") else "not synced"
        verified = "verified" if language.get("voice_slot_verified") else "not verified"
        print(
            f"Language       : {source} display -> {target} voice ({synced}, {verified}), preferred {preferred}"
        )
    if isinstance(selected, dict):
        bank_slots = selected.get("bank_slots")
        bank_part = (
            f"{bank_slots} bank slots" if isinstance(bank_slots, int) else "bank slots unknown"
        )
        print(
            f"Selected radio : R{selected.get('number')} {selected.get('name')} | "
            f"{selected.get('tracks')} XML tracks | "
            f"{bank_part} | "
            f"Free/Event {playlists.get('FreeRoam', 0)}/{playlists.get('Event', 0)}"
        )
    return 0
