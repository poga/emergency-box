#!/usr/bin/env python3
"""Pulls weather, news, and official alerts into chatto channels."""
import argparse
import configparser
import json
import os
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chatto_api

FLOOD_CAP = 10


def log(msg):
    print(msg, flush=True)


def fetch(url, state):
    req = urllib.request.Request(
        url, headers={"User-Agent": "emergency-box-botd"})
    with urllib.request.urlopen(req, timeout=10) as r:
        data = r.read()
    state["last_success"] = time.time()
    return data


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"last_success": time.time(), "offline": False}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, path)


class Poster:
    """One bot account bound to one room."""

    def __init__(self, url, login, password, room):
        self.url, self.login = url, login
        self.password, self.room = password, room
        self.client = None
        self.room_id = None

    def reset(self):
        self.client = None
        self.room_id = None

    def ready(self):
        if self.room_id:
            return
        c = chatto_api.Chatto(self.url)
        c.login(self.login, self.password)
        rooms = c.rpc("chatto.api.v1.RoomDirectoryService",
                      "ListRooms").get("rooms", [])
        found = None
        for r in rooms:
            if r["room"]["name"] == self.room:
                found = r["room"]
        if found is None:
            raise chatto_api.ChattoError("not_found", "room " + self.room)
        try:
            c.rpc("chatto.api.v1.RoomService", "JoinRoom",
                  {"roomId": found["id"]})
        except chatto_api.ChattoError:
            pass
        self.client, self.room_id = c, found["id"]

    def post(self, body):
        self.ready()
        self.client.rpc("chatto.api.v1.MessageService", "CreateMessage",
                        {"roomId": self.room_id, "body": body})


def weather_due(cfg, state, now):
    times = [t.strip() for t in cfg.get("weather", "post_times").split(",")]
    due = None
    for t in times:
        if now.strftime("%H:%M") >= t:
            due = "%s %s" % (now.strftime("%Y-%m-%d"), t)
    if due and state.get("weather", {}).get("last_slot") != due:
        return due
    return None


def weather_cycle(cfg, state, poster, force):
    slot = weather_due(cfg, state, datetime.now())
    if not slot:
        return
    url = cfg.get("weather", "url").format(
        latitude=cfg.get("location", "latitude"),
        longitude=cfg.get("location", "longitude"))
    d = json.loads(fetch(url, state))["daily"]
    name = cfg.get("location", "name")
    body = ("☀️ %s天氣預報\n"
            "今天 %.0f–%.0f°C，降雨機率 %d%%，最大風速 %.0f km/h\n"
            "明天 %.0f–%.0f°C，降雨機率 %d%%") % (
        name,
        d["temperature_2m_min"][0], d["temperature_2m_max"][0],
        d["precipitation_probability_max"][0], d["wind_speed_10m_max"][0],
        d["temperature_2m_min"][1], d["temperature_2m_max"][1],
        d["precipitation_probability_max"][1])
    poster.post(body)
    state.setdefault("weather", {})["last_slot"] = slot


CYCLES = (("weather", weather_cycle),)


def run_cycle(cfg, state, posters, force=False):
    for section, fn in CYCLES:
        try:
            fn(cfg, state, posters[section], force)
        except Exception as e:  # one failing bot must not stall the others
            log("%s: %s" % (section, e))
            posters[section].reset()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--once", action="store_true")
    args = ap.parse_args()
    cfg = configparser.ConfigParser(interpolation=None)
    cfg.read(args.config)
    state_file = cfg.get("botd", "state_file")
    state = load_state(state_file)
    posters = {
        s: Poster(cfg.get("botd", "chatto_url"), cfg.get(s, "login"),
                  cfg.get(s, "password"), cfg.get(s, "room"))
        for s in ("weather", "news", "alerts")
    }
    while True:
        run_cycle(cfg, state, posters, force=args.once)
        save_state(state_file, state)
        if args.once:
            return
        time.sleep(cfg.getint("botd", "tick", fallback=30))


if __name__ == "__main__":
    main()
