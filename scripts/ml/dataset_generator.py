"""Synthetic & adversarial casting notice dataset generator with strict Swift-parity grounding."""

from __future__ import annotations

import random
import re
import unicodedata
from typing import Optional

PROMPT_PREFIX = "parse audition notice:\n"
_STRIP_CHARS = " \t\"'.,;:-"


def _fold_diacritics(text: str) -> str:
    nfkd = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in nfkd if not unicodedata.combining(ch)).lower()


def is_grounded_notice_value(value: Optional[str], source: str) -> bool:
    """Matches `OnDeviceIntelligence.isGroundedNoticeValue(_:in:)` word-for-word."""
    if not value:
        return False
    candidate = value.strip(_STRIP_CHARS)
    if len(candidate) < 2 or candidate.lower() == "none":
        return False
    folded_candidate = _fold_diacritics(candidate)
    folded_source = _fold_diacritics(source)
    if folded_candidate in folded_source:
        return True
    words = [w for w in re.split(r"[^a-z0-9]+", candidate.lower()) if w]
    if not words:
        return False
    normalized_source = source.lower()
    matches = sum(1 for w in words if w in normalized_source)
    return (matches / len(words)) >= 0.75


def format_tagged_target(
    project: Optional[str],
    role: Optional[str],
    desc: Optional[str],
    deadline: Optional[str],
    email: Optional[str],
) -> str:
    """Formats the 5 target fields into strict single-line tagged format."""
    def clean(v: Optional[str]) -> str:
        if not v:
            return "NONE"
        s = " ".join(v.strip().split())
        s = (
            s.replace("\u2013", "-")
            .replace("\u2014", "-")
            .replace("\u2212", "-")
            .replace("\u2018", "'")
            .replace("\u2019", "'")
            .replace("\u201c", '"')
            .replace("\u201d", '"')
            .replace("\u2026", "...")
            .replace("\u20b9", "Rs.")
        )
        return s if s else "NONE"

    return "\n".join(
        [
            f"PROJECT: {clean(project)}",
            f"ROLE: {clean(role)}",
            f"DESC: {clean(desc)}",
            f"DEADLINE: {clean(deadline)}",
            f"EMAIL: {clean(email)}",
        ]
    )


_PROJECTS = [
    "MCCC - KOSHISHE",
    "PHOTON",
    "The Quiet Harbor",
    "Neon Horizon",
    "Midnight Express",
    "Monsoon Shadows",
    "Kala Pani",
    "Glass Harbor",
    "Echoes of Dawn",
    "Saffron & Rain",
    "Untold Verses",
    "Red Signal",
    "Dilli 1998",
    "Paper Boats",
    "The Last Audition",
    "Bombay Noir",
    "Silver Lining",
    "Naya Savera",
    "Starlight Diner",
    "Vanguard 7",
]

_STUDIOS = [
    "Yash Raj Films",
    "Casting Bay - Casting Studio",
    "Mukesh Chhabra Casting Co.",
    "Dharma Talent",
    "Excel Entertainment",
    "A24 Indie Unit",
    "Pinewood Casting",
    "Viacom18 Studio",
    "Balaji Telefilms",
    "Red Chillies Casting",
]

_ROLES = [
    "Male Lead",
    "Female Lead",
    "Female Talent",
    "Male Talent",
    "DETECTIVE COLE",
    "MAYA",
    "AARAV",
    "Supporting Lead",
    "Character Actor",
    "Young Father",
    "College Best Friend",
    "Senior Inspector",
    "Rohan (Second Lead)",
    "Grandmother",
    "Lead Vocalist",
]

_DESCS = [
    "Women aged 20–25 years with strong screen presence and natural expressions",
    "Men aged 22–25 years, fluent in Hindi & English, freshers welcome",
    "25–32 yrs, sharp comic timing, athletic build, Mumbai based preferred",
    "Age 18–24, South Asian look, comfortable with emotional monologue & Hindi dialogue",
    "30–40 years, theater background preferred, fluent English & conversational Marathi",
    "20–28 yrs old, natural improviser, guitar skills a plus",
    "Age 45–55, weathered authoritative voice, shoot in Delhi & Mumbai",
    "Fresh female faces 19–24 years for upcoming Hindi theatrical feature film",
]

_DEADLINES = [
    "15 December, 2026",
    "30 November 2026",
    "December 15, 2026 at 5:00 PM",
    "30/11/2026 17:00",
    "Nov 30, 2026 5:00 PM",
    "2026-12-15",
    "18 Jan 2027",
    "Monday, 24th Nov 6 PM",
    "05/02/2027",
    "12 March 2027 EOD",
]

_SHOOT_DATES = [
    "10 January 2027",
    "February 2027 (25 days schedule)",
    "02/03/2027 – 18/03/2027",
    "mid-April 2027",
]

_SUBMISSION_EMAILS = [
    "abhinav@mcc.in",
    "casting@schoolofdrama.com",
    "profilesforlead@gmail.com",
    "casting@neonfilm.com",
    "auditions@midnight.org",
    "selftape@monsoonfilms.in",
    "talent.mumbai@castingbay.co.in",
    "submit.koshishe@gmail.com",
    "submissions@harborpictures.com",
]

_DECOY_EMAILS = [
    "agent@talentagency.com",
    "info@studiooffice.in",
    "press@productionhouse.com",
    "queries@mumbaifilms.org",
    "desk@management.co.uk",
]


def _pick(rng: random.Random, items: list[str]) -> str:
    return items[rng.randrange(len(items))]


_TITLE_ADJ = ["Broken", "Velvet", "Silent", "Crimson", "Golden", "Last", "Parallel", "Copper", "Distant", "Wandering", "Urban", "Hidden", "Wild", "Electric"]
_TITLE_NOUN = ["Monsoon", "Platform", "Echo", "Bridge", "Compass", "Cinema", "Notebook", "Harbor", "Station", "Courtyard", "Skyline", "Letter", "Lantern", "Waves"]
_ROLE_ADJ = ["Young", "Senior", "Supporting", "Lead", "Primary", "Rookie", "Charming", "Ruthless", "Soft-spoken"]
_ROLE_NOUN = ["Detective", "Journalist", "Doctor", "Architect", "Musician", "Protagonist", "Antagonist", "Lawyer", "Professor", "Dancer"]
_CITIES = ["Mumbai", "Delhi", "Bengaluru", "Kolkata", "Pune", "Jaipur", "Hyderabad", "London"]
_MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
_DOMAINS = ["castingunit.in", "filmcraft.co.in", "studionext.com", "indiefilms.org", "talentdesk.in", "selftapes.com"]


def _gen_project(rng: random.Random) -> str:
    if rng.random() < 0.45:
        return _pick(rng, _PROJECTS)
    mode = rng.randrange(3)
    if mode == 0:
        return f"{_pick(rng, _TITLE_ADJ)} {_pick(rng, _TITLE_NOUN)}"
    if mode == 1:
        tag = "".join(rng.choice("ABCDEFGHIJKLMNOPQRSTUVWXYZ") for _ in range(rng.randint(3, 5)))
        return f"{tag} - {_pick(rng, _TITLE_NOUN).upper()}"
    return f"The {_pick(rng, _TITLE_ADJ)} {_pick(rng, _TITLE_NOUN)} S{rng.randint(1, 3)}"


def _gen_role(rng: random.Random) -> str:
    if rng.random() < 0.45:
        return _pick(rng, _ROLES)
    if rng.random() < 0.5:
        return f"{_pick(rng, _ROLE_ADJ)} {_pick(rng, _ROLE_NOUN)}"
    first = rng.choice(["Aryan", "Meera", "Kabir", "Naina", "Vikram", "Tara", "Dev", "Zoya", "Rhea", "Samar"])
    return f"{first} ({rng.choice(['Lead', 'Parallel Lead', 'Supporting'])})"


def _gen_desc(rng: random.Random) -> str:
    if rng.random() < 0.45:
        return _pick(rng, _DESCS)
    low = rng.randint(18, 45)
    high = low + rng.randint(4, 10)
    dash = rng.choice(["-", "\u2013"])
    gender = rng.choice(["Male", "Female", "Any gender", "Actors"])
    trait = rng.choice([
        "strong screen presence",
        "fluent Hindi & English",
        "theater background preferred",
        "natural expressions",
        "comic timing & improvisation",
    ])
    return f"{gender}, age {low}{dash}{high} yrs, {trait}, shoot in {_pick(rng, _CITIES)}"


def _gen_deadline(rng: random.Random) -> str:
    if rng.random() < 0.45:
        return _pick(rng, _DEADLINES)
    day = rng.randint(1, 28)
    mon = _pick(rng, _MONTHS)
    yr = rng.choice([2026, 2027])
    hr = rng.choice(["5 PM", "6:00 PM", "11:59 PM", "EOD"])
    return rng.choice([
        f"{day} {mon}, {yr}",
        f"{mon[:3]} {day}, {yr} {hr}",
        f"{day:02d}/{rng.randint(1, 12):02d}/{yr}",
        f"{yr}-{rng.randint(1, 12):02d}-{day:02d}",
    ])


def _gen_email(rng: random.Random) -> str:
    if rng.random() < 0.45:
        return _pick(rng, _SUBMISSION_EMAILS)
    prefix = rng.choice(["cast", "audition", "submissions", "talent", "projects", "team"])
    mid = rng.choice(["", ".mumbai", ".casting", "2026"])
    return f"{prefix}{mid}@{_pick(rng, _DOMAINS)}"


def _ocr_jitter(rng: random.Random, text: str) -> str:
    lines = text.splitlines()
    out = []
    for line in lines:
        if rng.random() < 0.15:
            line = line.replace(":", " : ").replace("  ", " ")
        if rng.random() < 0.10:
            line = f"• {line}"
        out.append(line)
    joined = "\n".join(out)
    if rng.random() < 0.12:
        joined = joined.replace("Role:", "ROLE -").replace("Deadline:", "Last Date:")
    return joined


def _build_sample(rng: random.Random, category: str) -> dict[str, str]:
    project = _gen_project(rng)
    studio = _pick(rng, _STUDIOS)
    role = _gen_role(rng)
    desc = _gen_desc(rng)
    deadline = _gen_deadline(rng)
    sub_email = _gen_email(rng)
    decoy_email = _pick(rng, _DECOY_EMAILS)
    shoot_date = _pick(rng, _SHOOT_DATES)

    if category == "standard_labeled":
        header = rng.choice(["CASTING CALL", "AUDITION NOTICE", "URGENT REQUIREMENT", "OPEN CASTING"])
        text = (
            f"{header}\n"
            f"Project: {project}\n"
            f"Production: {studio}\n"
            f"Role: {role}\n"
            f"Profile: {desc}\n"
            f"Requirements: 30s slate + 2 min self-tape\n"
            f"Submission Deadline: {deadline}\n"
            f"Send profile & tape to: {sub_email}"
        )
        target = format_tagged_target(project, role, desc, deadline, sub_email)

    elif category == "dual_email_trap":
        text = (
            f"CASTING BREAKDOWN — {project}\n"
            f"Agency Contact: {decoy_email} (general queries only)\n"
            f"Production House: {studio}\n"
            f"Looking for: {role}\n"
            f"Details: {desc}\n"
            f"Submit self-tape & headshots strictly to: {sub_email}\n"
            f"Last Date to Apply: {deadline}"
        )
        target = format_tagged_target(project, role, desc, deadline, sub_email)

    elif category == "dual_date_trap":
        text = (
            f"{project} - UPCOMING FEATURE FILM\n"
            f"Tentative Shoot Dates: {shoot_date} in Mumbai\n"
            f"Character: {role} ({desc})\n"
            f"Audition Deadline: {deadline}\n"
            f"Mail entries to {sub_email}\n"
            f"Do not apply after {deadline}."
        )
        target = format_tagged_target(project, role, desc, deadline, sub_email)

    elif category == "missing_fields":
        omit_mode = rng.choice(["no_deadline", "no_email", "no_project", "no_deadline_no_email"])
        if omit_mode == "no_deadline":
            text = (
                f"CASTING CALL - {project}\n"
                f"Role: {role}\n"
                f"Brief: {desc}\n"
                f"Send self-tape to {sub_email}"
            )
            target = format_tagged_target(project, role, desc, None, sub_email)
        elif omit_mode == "no_email":
            text = (
                f"CASTING CALL – {project}\n"
                f"{studio} is looking for {role}. {desc}.\n"
                f"Audition Deadline: {deadline}. Shortlisted candidates will be contacted."
            )
            target = format_tagged_target(project, role, desc, deadline, None)
        elif omit_mode == "no_project":
            text = (
                f"CASTING CALL – UPCOMING HINDI FEATURE FILM\n"
                f"{studio} is looking for {role}. {desc}. Freshers are welcome.\n"
                f"Audition Deadline: {deadline}\n"
                f"Email: {sub_email}"
            )
            target = format_tagged_target(None, role, desc, deadline, sub_email)
        else:
            text = (
                f"REQUIREMENT FOR {project}\n"
                f"Seeking {role}: {desc}.\n"
                f"Send 3 recent pictures and intro video."
            )
            target = format_tagged_target(project, role, desc, None, None)

    elif category == "whatsapp_prose":
        city = rng.choice(["Mumbai", "Delhi", "Hyderabad", "London"])
        text = (
            f"Hi actors!! Casting for {project} ({studio}).\n"
            f"We need {role} — {desc}. Shoot in {city}.\n"
            f"Please share 2–3 recent headshots, intro clip, and audition video performing attached sides.\n"
            f"Kindly mail everything before {deadline} on {sub_email}. No fees!"
        )
        target = format_tagged_target(project, role, desc, deadline, sub_email)

    elif category == "trailing_sides":
        text = (
            f"PROJECT: {project}\n"
            f"ROLE: {role}\n"
            f"NOTE: {desc}\n"
            f"DUE: {deadline}\n"
            f"SUBMIT: {sub_email}\n\n"
            f"--- AUDITION SIDES ---\n"
            f"INT. CAFE - NIGHT (December 1, 1999)\n"
            f"DETECTIVE: Did you mail info@fake-dialogue.com yesterday?\n"
            f"PRIYA: No, I waited until Friday night."
        )
        target = format_tagged_target(project, role, desc, deadline, sub_email)

    else:  # noisy_ocr (including multi-column flattening & symbols like –, ₹, |)
        raw = (
            f"CASTING CALL | {project}\n"
            f"{studio} | Role: {role}\n"
            f"{desc} | Compensation ₹25,000/day\n"
            f"Deadline: {deadline}\n"
            f"Email to Apply: {sub_email}"
        )
        text = _ocr_jitter(rng, raw)
        target = format_tagged_target(project, role, desc, deadline, sub_email)

    return {
        "category": category,
        "input": f"{PROMPT_PREFIX}{text}",
        "target": target,
    }


def generate_casting_corpus(
    num_train: int = 18000,
    num_val: int = 1000,
    num_test: int = 1000,
    seed: int = 42,
) -> dict[str, list[dict[str, str]]]:
    """Generates balanced train/val/test splits verified against Swift's grounding rule."""
    rng = random.Random(seed)
    categories = [
        "standard_labeled",
        "dual_email_trap",
        "dual_date_trap",
        "missing_fields",
        "whatsapp_prose",
        "trailing_sides",
        "noisy_ocr",
    ]

    def build_split(count: int) -> list[dict[str, str]]:
        rows: list[dict[str, str]] = []
        for idx in range(count):
            cat = categories[idx % len(categories)]
            rows.append(_build_sample(rng, cat))
        rng.shuffle(rows)
        return rows

    return {
        "train": build_split(num_train),
        "val": build_split(num_val),
        "test": build_split(num_test),
    }
