"""Tests for bin/agent-shell-crew-mcp, with emacsclient replaced by a fake."""
import base64, json, os, stat, subprocess, sys, tempfile, unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROGRAM = os.path.join(ROOT, "bin", "agent-shell-crew-mcp")

FAKE = r"""#!/usr/bin/env python3
import json, os, sys
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write(json.dumps(sys.argv[1:]) + "\n")
# FAKE_SLEEP_ONCE: the first call hangs past the timeout, as a slow Emacs did.
marker = os.environ["FAKE_LOG"] + ".slept"
if os.environ.get("FAKE_SLEEP_ONCE") and not os.path.exists(marker):
    open(marker, "w").close()
    import time; time.sleep(float(os.environ["FAKE_SLEEP_ONCE"]))
sys.stdout.write(os.environ.get("FAKE_REPLY", ""))
sys.exit(int(os.environ.get("FAKE_RC", "0")))
"""

def reply(obj):
    return '"' + base64.b64encode(json.dumps(obj).encode()).decode() + '"\n'

class McpTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.fake = os.path.join(self.tmp, "emacsclient")
        with open(self.fake, "w") as f:
            f.write(FAKE)
        os.chmod(self.fake, os.stat(self.fake).st_mode | stat.S_IEXEC)
        self.log = os.path.join(self.tmp, "calls.log")
        self.env = dict(os.environ, CREW_AGENT="owner@my-app", CREW_PROJECT="/tmp/my-app/",
                        CREW_EMACS_SOCKET="/tmp/sock", CREW_EMACSCLIENT=self.fake,
                        FAKE_LOG=self.log, FAKE_REPLY=reply({"ok": True, "result": {"id": "c-1"}}))

    def run_session(self, messages, **env):
        e = dict(self.env, **env)
        data = "".join(json.dumps(m) + "\n" for m in messages)
        out = subprocess.run([sys.executable, PROGRAM], input=data, capture_output=True,
                             text=True, env=e, timeout=30)
        return [json.loads(line) for line in out.stdout.splitlines() if line.strip()]

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [json.loads(line) for line in f]

    def request(self, argv):
        """Decode the request the MCP program sent to Emacs."""
        expr = argv[-1]
        payload = expr.split('"')[1]
        return json.loads(base64.b64decode(payload))

    def test_initialize_and_list_tools(self):
        out = self.run_session([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
        self.assertEqual(len(out), 2)
        self.assertEqual(out[0]["result"]["serverInfo"]["name"], "agent-shell-crew")
        self.assertEqual(out[0]["result"]["protocolVersion"], "2025-06-18")
        names = {t["name"] for t in out[1]["result"]["tools"]}
        self.assertEqual(names, {"crew_mine", "crew_list", "crew_show", "crew_create", "crew_claim",
                                 "crew_note", "crew_handoff", "crew_stage", "crew_park", "crew_done",
                                 "crew_checkpoint"})

    def test_call_forwards_with_identity_from_environment(self):
        out = self.run_session([{"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                                 "params": {"name": "crew_claim",
                                            "arguments": {"id": "c-1", "actor": "human"}}}])
        self.assertFalse(out[0]["result"]["isError"])
        argv = self.calls()[0]
        self.assertEqual(argv[:2], ["-s", "/tmp/sock"])
        self.assertTrue(argv[-1].startswith("(agent-shell-crew-rpc \""))
        req = self.request(argv)
        self.assertEqual(req["actor"], "owner@my-app")
        self.assertEqual(req["project"], "/tmp/my-app/")
        self.assertEqual(req["verb"], "claim")
        self.assertEqual(req["args"], {"id": "c-1"})  # smuggled actor dropped

    def test_emacs_error_becomes_tool_error(self):
        out = self.run_session([{"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                 "params": {"name": "crew_claim", "arguments": {"id": "c-1"}}}],
                               FAKE_REPLY=reply({"ok": False, "error": "check@x does not own c-1"}))
        self.assertTrue(out[0]["result"]["isError"])
        self.assertIn("does not own", out[0]["result"]["content"][0]["text"])

    def test_unreachable_emacs_becomes_tool_error(self):
        out = self.run_session([{"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                                 "params": {"name": "crew_list", "arguments": {}}}],
                               FAKE_RC="1", FAKE_REPLY="")
        self.assertTrue(out[0]["result"]["isError"])
        self.assertIn("reach Emacs", out[0]["result"]["content"][0]["text"])

    def test_a_long_reply_ending_in_an_escaped_newline_is_read(self):
        """emacsclient ends a long reply `"&n`; it was read as garbage (2026-10-12)."""
        out = self.run_session([{"jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                 "params": {"name": "crew_list", "arguments": {}}}],
                               FAKE_REPLY=reply({"ok": True, "result": [{"id": "c-9"}]}).rstrip("\n") + "&n")
        self.assertFalse(out[0]["result"]["isError"])
        self.assertIn("c-9", out[0]["result"]["content"][0]["text"])

    def test_unknown_tool_and_method(self):
        out = self.run_session([
            {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "rm", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 7, "method": "nope"}])
        self.assertTrue(out[0]["result"]["isError"])
        self.assertEqual(out[1]["error"]["code"], -32601)

    def test_unicode_arguments_pass_through(self):
        title = "Fix “quotes” and \"these\" and \\ and 日本 and 🚀"
        self.run_session([{"jsonrpc": "2.0", "id": 8, "method": "tools/call",
                           "params": {"name": "crew_create",
                                      "arguments": {"title": title, "owner": "check@my-app", "brief": "b"}}}])
        self.assertEqual(self.request(self.calls()[0])["args"]["title"], title)

    def create(self, arguments, **env):
        return self.run_session([{"jsonrpc": "2.0", "id": 9, "method": "tools/call",
                                  "params": {"name": "crew_create", "arguments": arguments}}], **env)

    def test_create_gets_a_request_id_when_the_agent_gives_none(self):
        self.create({"title": "t", "owner": "check@my-app", "brief": "b"})
        rid = self.request(self.calls()[0])["args"]["request_id"]
        self.assertEqual(len(rid), 36)

    def test_an_agents_own_request_id_is_kept(self):
        self.create({"title": "t", "owner": "check@my-app", "brief": "b", "request_id": "r-1"})
        self.assertEqual(self.request(self.calls()[0])["args"]["request_id"], "r-1")

    def test_a_timed_out_create_is_retried_once_with_the_same_request_id(self):
        """2026-10-07: crew_create timed out but Emacs had made the item."""
        out = self.create({"title": "t", "owner": "check@my-app", "brief": "b"},
                          FAKE_SLEEP_ONCE="3", CREW_RPC_TIMEOUT="1")
        self.assertFalse(out[0]["result"]["isError"])
        ids = [self.request(c)["args"]["request_id"] for c in self.calls()]
        self.assertEqual(len(ids), 2)
        self.assertEqual(ids[0], ids[1])

    def test_a_timed_out_claim_is_not_retried(self):
        out = self.run_session([{"jsonrpc": "2.0", "id": 10, "method": "tools/call",
                                 "params": {"name": "crew_claim", "arguments": {"id": "c-1"}}}],
                               FAKE_SLEEP_ONCE="3", CREW_RPC_TIMEOUT="1")
        self.assertTrue(out[0]["result"]["isError"])
        self.assertEqual(len(self.calls()), 1)

if __name__ == "__main__":
    unittest.main()
