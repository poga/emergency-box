#!/usr/bin/env python3
"""Seeds the emergency channel structure in chatto. Idempotent."""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import chatto_api

ADMIN_LAYOUT = "chatto.admin.v1.AdminRoomLayoutService"
ADMIN_PERM = "chatto.admin.v1.AdminPermissionService"
ROOM_SVC = "chatto.api.v1.RoomService"

GROUP_RENAMES = {"Lobby": "大廳"}
ROOM_RENAMES = {"general": "chat"}
GROUPS = ["大廳", "緊急互助", "資訊"]
ROOMS = [
    ("大廳", "announcements", "公告｜版主發布重要資訊"),
    ("大廳", "chat", "閒聊｜日常聊天"),
    ("緊急互助", "help", "求助｜需要幫忙就在這裡說"),
    ("緊急互助", "supplies", "物資｜水、食物、電源、藥品互通有無"),
    ("緊急互助", "civil-defense", "民防｜防空、避難所、戰時資訊"),
    ("資訊", "weather", "天氣｜天氣機器人自動發布"),
    ("資訊", "news", "新聞｜新聞機器人自動發布"),
    ("資訊", "alerts", "警報｜地震、颱風等官方警報自動發布"),
]


def read_credentials(path):
    creds = {}
    with open(path) as f:
        for line in f:
            if ":" in line:
                k, v = line.split(":", 1)
                creds[k.strip()] = v.strip()
    return creds["login"], creds["password"]


def layout(c):
    groups = c.rpc(ADMIN_LAYOUT, "ListRoomGroups").get("groups", [])
    by_name = {g["name"]: g for g in groups}
    rooms = {}
    for g in groups:
        for item in g.get("items", []):
            room = item.get("room")
            if room:
                rooms[room["name"]] = room
    return by_name, rooms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--credentials", required=True)
    args = ap.parse_args()
    login, password = read_credentials(args.credentials)
    c = chatto_api.Chatto(args.url)
    c.login(login, password)

    groups, rooms = layout(c)
    for old, new in GROUP_RENAMES.items():
        if old in groups and new not in groups:
            c.rpc(ADMIN_LAYOUT, "UpdateRoomGroup",
                  {"groupId": groups[old]["id"], "name": new})
    for old, new in ROOM_RENAMES.items():
        if old in rooms and new not in rooms:
            c.rpc(ROOM_SVC, "UpdateRoom",
                  {"roomId": rooms[old]["id"], "name": new})

    groups, rooms = layout(c)
    for name in GROUPS:
        if name not in groups:
            c.rpc(ADMIN_LAYOUT, "CreateRoomGroup", {"name": name})

    groups, rooms = layout(c)
    for group, name, desc in ROOMS:
        if name not in rooms:
            c.rpc(ROOM_SVC, "CreateRoom",
                  {"name": name, "groupId": groups[group]["id"],
                   "description": desc, "universal": True})
        elif (rooms[name].get("description") != desc
              or not rooms[name].get("universal")):
            c.rpc(ROOM_SVC, "UpdateRoom",
                  {"roomId": rooms[name]["id"], "description": desc,
                   "universal": True})

    groups, rooms = layout(c)
    scope = {"kind": "PERMISSION_SCOPE_KIND_ROOM",
             "id": rooms["announcements"]["id"]}
    c.rpc(ADMIN_PERM, "SetRolePermission",
          {"roleName": "everyone", "permission": "message.post",
           "scope": scope, "decision": "PERMISSION_DECISION_DENY"})
    c.rpc(ADMIN_PERM, "SetRolePermission",
          {"roleName": "moderator", "permission": "message.post",
           "scope": scope, "decision": "PERMISSION_DECISION_ALLOW"})
    print("seeded: %d groups, %d rooms" % (len(GROUPS), len(ROOMS)))


if __name__ == "__main__":
    main()
