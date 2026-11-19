import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentDockStopTests {
    @Test func terminalWordsKeepStoppedDistinctFromDoneAndFailed() {
        let session = Agents.Session(id: "dock-words", cli: "claude", name: "Claude", prompt: "", state: .stopped)
        session.result = "A partial answer"
        #expect(AgentDock.finishedWords(session) == "You stopped Claude")
        session.state = .attached
        #expect(AgentDock.finishedWords(session, stopped: true) == "You stopped Claude")
        session.state = .failed
        #expect(AgentDock.finishedWords(session) == "Claude couldn’t finish")
        session.state = .done
        #expect(AgentDock.finishedWords(session) == "Done · A partial answer")
    }

    @Test func stopShortcutHasItsOwnChordAndContext() {
        let key = Hotkey(".", [.shift, .command])
        #expect(Shortcut.byAction[.agentStop]?.key == key)
        #expect(Shortcut.context(.agentStop) == .agent)
        #expect(Keymap.valid(key, for: .agentStop))
        #expect(Hotkeys.action(forTitle: "Stop Agent") == .agentStop)
        #expect(Keymap.conflicts(.agentStop, Hotkey("t", .command), .fieldActions, Hotkey("t", .command)))
    }

    @Test(arguments: [false, true])
    func attachedStopReleasesOnlyThisTabAndRefusesFurtherCalls(driving: Bool) {
        _ = NSApplication.shared
        let agents = Agents.shared
        let session = agents.attach(name: "Claude")
        let tab = Tab(bench: true), other = Tab(bench: true)
        tab.agent = session.id
        other.agent = session.id
        let browser = Browser(windowID: UUID())
        let oldBrowser = agents.browser, oldFeedBrowser = AgentFeed.shared.browser
        browser.lay([tab, other])
        browser.activeID = tab.id
        agents.browser = browser
        AgentFeed.shared.browser = browser
        defer {
            agents.browser = oldBrowser
            AgentFeed.shared.browser = oldFeedBrowser
            tab.close(); other.close(); browser.letGo()
        }
        tab.allowed.insert(session.id)
        AgentFeed.shared.did(tab, .read)
        if driving {
            AgentFeed.shared.drive(tab)
            #expect(AgentFeed.shared.driving.contains(tab.id))
        }
        #expect(agents.stop(on: tab))
        #expect(session.state == .attached)
        #expect(session.process == nil)
        #expect(tab.worker == nil)
        #expect(!tab.allowed.contains(session.id))
        #expect(!AgentFeed.shared.driving.contains(tab.id))
        #expect(AgentFeed.shared.pointer[tab.id] == nil)
        #expect(AgentFeed.shared.stopped[tab.id] == session.id)
        #expect(other.worker == session.id)
        #expect(agents.stoppedOnTab(tab, session: session.id) == "The person stopped you on this tab.")
        #expect(agents.stoppedOnTab(other, session: session.id) == nil)
        #expect(agents.stoppedOnTab(tab, session: "another-agent") == nil)
        #expect(!agents.stop(on: tab))
        agents.detach(session.id)
    }

    @Test func ownedStopKeepsThePageAndTheStoppedChatItem() {
        _ = NSApplication.shared
        let agents = Agents.shared
        let session = agents.attach(name: "Claude")
        session.cli = "claude"
        session.state = .running
        let tab = Tab(bench: true)
        tab.agent = session.id
        tab.restore(url: URL(string: "about:blank#kept")!, title: "Kept page")
        #expect(agents.stop(on: tab))
        #expect(session.state == .stopped)
        #expect(session.items.contains { $0.name == ChatItem.stopped })
        #expect(tab.address?.absoluteString == "about:blank#kept")
        #expect(!agents.stop(on: tab))
    }

    @Test func scriptStopReleasesThePageAndRejectsSessionlessCalls() {
        let tab = Tab(bench: true)
        let session = Agents.shared.scripted()
        tab.agent = session.id
        #expect(Agents.shared.stop(on: tab))
        #expect(session.state == .attached)
        #expect(tab.worker == nil)
        #expect(Agents.shared.stoppedOnTab(tab, session: nil) == "The person stopped you on this tab.")
    }

    @Test func releasedTabRejectsReadsBeforeWakingOrReclaimingIt() {
        _ = NSApplication.shared
        let browser = Browser(windowID: UUID())
        let tab = Tab(bench: true)
        let session = Agents.shared.attach(name: "Claude")
        tab.agent = session.id
        browser.lay([tab])
        browser.activeID = tab.id
        #expect(Agents.shared.stop(on: tab))
        var reply: [String: Any] = [:]
        Bench().agentCommand("snapshot", ["id": tab.id.uuidString, "session": session.id], browser: browser) { reply = $0 }
        #expect(reply["error"] as? String == "The person stopped you on this tab.")
        #expect(tab.worker == nil)
        for verb in ["handoff", "agent-go", "agent-eval"] {
            reply = [:]
            Bench().agentCommand(verb, ["id": tab.id.uuidString, "session": session.id], browser: browser) { reply = $0 }
            #expect(reply["error"] as? String == "The person stopped you on this tab.")
        }
        #expect(browser.tabs.contains { $0 === tab })
        Agents.shared.detach(session.id)
        tab.close()
        browser.letGo()
    }

    /// #964: Stop leaves the thread inside the killed handoff, so the next
    /// message on it must say the person stopped it, and the handoff is gone.
    @Test func aMessageAfterStopTellsTheAgentNotToResume() {
        _ = NSApplication.shared
        let agents = Agents()
        let consent = ProviderConsent.shared
        consent.grant("claude")
        defer { consent.revoke("claude") }
        let tab = Tab(bench: true)
        let browser = Browser(windowID: UUID())
        browser.lay([tab])
        agents.browser = browser
        defer { tab.close(); browser.letGo() }
        let session = Agents.Session(id: "stopped-964", cli: "claude", name: "Claude", prompt: "Send the link", state: .running)
        agents.register(session)
        tab.agent = session.id
        tab.handoff = "Sign in to the app"
        #expect(agents.stop(session.id))
        #expect(tab.handoff == nil)
        let next = agents.run(prompt: "no, from the page I'm on", cli: nil, access: "browser", resume: session.id)
        defer { next.turnPermit.revoke(); next.state = .failed }
        #expect(next === session)
        // The person's words stay the prompt; the note goes only to the agent.
        #expect(session.prompt == "no, from the page I'm on")
        #expect(session.told.last == "no, from the page I'm on")
        #expect(session.afterStop)
        let sent = Agents.said(session.prompt, afterStop: session.afterStop)
        #expect(sent.hasPrefix(Agents.stoppedLine))
        #expect(sent.contains("Don't resume or retry"))
        #expect(sent.hasSuffix("no, from the page I'm on"))
        #expect(Agents.unsaid(sent) == "no, from the page I'm on")
    }

    /// A stand-in Claude Code: logs each line it is written, answers, stays up.
    private func stand(in root: URL) throws -> URL {
        let binary = root.appendingPathComponent("claude-stub")
        try #"""
        #!/usr/bin/python3
        import json, os, sys
        print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'stub'}), flush=True)
        for line in sys.stdin:
            message = json.loads(line)
            text = ''.join(part['text'] for part in message['message']['content'])
            with open(os.environ['STUB_LOG'], 'a') as output:
                output.write(json.dumps(text) + '\n')
            print(json.dumps({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': 'stub', 'result': 'ok', 'num_turns': 1}), flush=True)
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        return binary
    }

    /// The reviewer's path (#964): Stop, then a message whose launch fails,
    /// then a retry that launches. The note is owed through the failure and
    /// handed over once, with the retry; the person's words are never changed.
    @Test func theStopNoteSurvivesAFailedLaunchAndIsDeliveredOnce() async throws {
        try #require(Store.testing)
        _ = NSApplication.shared
        let agents = Agents()
        let consent = ProviderConsent.shared
        consent.grant("claude")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stop-note-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("wire.log")
        let session = Agents.Session(id: "retry-964-" + UUID().uuidString, cli: "claude", name: "Claude", prompt: "Send the link", state: .running)
        let room = Store.file("agent/\(session.id)")
        defer {
            try? session.input?.close()
            if session.process?.isRunning == true { session.process?.terminate() }
            try? FileManager.default.removeItem(at: room)
            try? FileManager.default.removeItem(at: root)
            consent.revoke("claude")
        }
        agents.register(session)
        session.binary = try stand(in: root).path
        session.env = ["STUB_LOG": log.path]
        func lines() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) as? String
            }
        }
        /// run() admits the message and queues the real launch; this test
        /// starts it by hand, so that one is refused first.
        func admit(_ words: String) async {
            let again = agents.run(prompt: words, cli: nil, access: "browser", resume: session.id)
            #expect(again === session)
            session.turnPermit.revoke()
            for _ in 0..<5 { await Task.yield() }
            session.state = .starting
            session.result = ""
            session.turnPermit = AgentTurnPermit()
        }

        #expect(agents.stop(session.id))
        #expect(session.state == .stopped)

        // A file where its folder goes: the launch throws (finish .failed).
        try FileManager.default.createDirectory(at: room.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: room)
        await admit("first try")
        #expect(session.afterStop)
        agents.start(session, message: session.prompt)
        #expect(session.state == .failed)
        #expect(session.process == nil)
        // Not spent by a launch that never handed it over.
        #expect(session.afterStop)

        try FileManager.default.removeItem(at: room)
        await admit("second try")
        #expect(session.afterStop, "a failed launch's note is not lost when the next message is admitted")
        agents.start(session, message: session.prompt)
        #expect(session.state == .running)
        #expect(!session.afterStop)
        let wrote = await {
            let until = ProcessInfo.processInfo.systemUptime + 30
            while lines().isEmpty, ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(for: .milliseconds(10)) }
            return lines()
        }()
        #expect(wrote == [Agents.stoppedLine + "second try"])
        #expect(wrote.joined().components(separatedBy: Agents.stoppedLine).count - 1 == 1)
        // The person's own words, nothing else, in what is kept and shown.
        #expect(session.prompt == "second try")
        #expect(session.told.suffix(2) == ["first try", "second try"])
        #expect(!session.told.contains { $0.contains(Agents.stoppedLine) })
        #expect(session.items.filter { $0.kind == .asked }.allSatisfy { !$0.text.contains("stopped you") })
    }

    /// #964: a handoff waiting in a tab of another window goes with Stop,
    /// which `tabs(of:)` (this window's alone) missed.
    @Test func stopClearsAHandoffInAnotherWindow() {
        _ = NSApplication.shared
        let agents = Agents()
        let first = Browser(windowID: UUID()), second = Browser(windowID: UUID())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        BrowserWindows.shared.register(window, for: second)
        let mine = Tab(bench: true), theirs = Tab(bench: true)
        first.lay([mine])
        second.lay([theirs])
        agents.browser = first
        defer {
            mine.close(); theirs.close()
            BrowserWindows.shared.forgetForTests(second)
            window.close()
            first.letGo(); second.letGo()
        }
        let session = Agents.Session(id: "windows-964", cli: "claude", name: "Claude", prompt: "Send the link", state: .running)
        agents.register(session)
        theirs.agent = session.id
        theirs.handoff = "Sign in to the app"
        #expect(agents.tabs(of: session).isEmpty)
        #expect(agents.windowTabs.contains { $0 === theirs })
        #expect(agents.stop(session.id))
        #expect(theirs.handoff == nil)
    }

    @Test func aMessageAfterANormalTurnIsLeftAlone() {
        let agents = Agents()
        let consent = ProviderConsent.shared
        consent.grant("claude")
        defer { consent.revoke("claude") }
        let session = Agents.Session(id: "done-964", cli: "claude", name: "Claude", prompt: "Hi", state: .done)
        agents.register(session)
        let next = agents.run(prompt: "And then?", cli: nil, access: "browser", resume: session.id)
        defer { next.turnPermit.revoke(); next.state = .failed }
        #expect(session.prompt == "And then?")
        #expect(!session.afterStop)
        #expect(Agents.said(session.prompt, afterStop: session.afterStop) == "And then?")
    }
}
