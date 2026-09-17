import Foundation

/// The look and the study controls of a shared deck's page. Everything is inline, so the file
/// works offline, in Quick Look, and in email, and prints as a plain card list.
nonisolated extension DeckShare {
    static let styles = #"""
        :root {
            color-scheme: light dark;
            --bg: #f2f2f7;
            --card: #ffffff;
            --text: #1c1c1e;
            --muted: #6c6c70;
            --line: #d8d8dd;
            --accent: #0b5fd0;
            --flag: #b64607;
            --flag-bg: #fdefe6;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg: #000000;
                --card: #1c1c1e;
                --text: #f2f2f7;
                --muted: #98989f;
                --line: #38383c;
                --accent: #62a0ff;
                --flag: #ff9f5a;
                --flag-bg: #3a2312;
            }
        }
        * { box-sizing: border-box; }
        body {
            margin: 0;
            background: var(--bg);
            color: var(--text);
            font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            -webkit-text-size-adjust: 100%;
        }
        main { max-width: 44rem; margin: 0 auto; padding: 24px 16px 48px; }
        h1 { font-size: 1.75rem; line-height: 1.2; margin: 0 0 6px; }
        h2 { font-size: 1.05rem; text-transform: uppercase; letter-spacing: 0.04em; color: var(--muted); margin: 32px 0 10px; }
        header .count { margin: 0; color: var(--muted); font-size: 0.95rem; }
        .visually-hidden {
            position: absolute; width: 1px; height: 1px; margin: -1px;
            overflow: hidden; clip-path: inset(50%); white-space: nowrap;
        }
        #card {
            display: flex; flex-direction: column; gap: 10px; justify-content: center; align-items: center;
            width: 100%; min-height: 220px; margin-top: 16px; padding: 28px 20px;
            background: var(--card); color: var(--text);
            border: 1px solid var(--line); border-radius: 18px;
            font: inherit; text-align: center; cursor: pointer;
            -webkit-tap-highlight-color: transparent;
        }
        #card:hover { border-color: var(--accent); }
        #card.priority { border-color: var(--flag); }
        #side-label {
            font-size: 0.7rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em;
            color: var(--muted);
        }
        #card.answer #side-label { color: var(--accent); }
        #card-text { font-size: 1.35rem; font-weight: 600; }
        #card.answer #card-text { font-weight: 500; }
        .hint { font-size: 0.8rem; color: var(--muted); }
        .controls { display: flex; align-items: center; justify-content: center; gap: 18px; margin-top: 14px; }
        .controls button {
            width: 46px; height: 40px; border-radius: 12px; cursor: pointer;
            background: var(--card); color: var(--accent); border: 1px solid var(--line);
            font-size: 1.4rem; line-height: 1;
        }
        .controls button:hover { border-color: var(--accent); }
        #progress { margin: 0; min-width: 11rem; text-align: center; color: var(--muted); font-size: 0.9rem; }
        ol.cards { list-style: none; margin: 0; padding: 0; }
        ol.cards li {
            padding: 14px 16px; margin-bottom: 8px;
            background: var(--card); border: 1px solid var(--line); border-radius: 12px;
        }
        ol.cards li.priority { border-left: 4px solid var(--flag); }
        .q { margin: 0 0 4px; font-weight: 600; }
        .a { margin: 0; color: var(--muted); }
        .flag {
            display: inline-block; margin-left: 8px; padding: 1px 7px; border-radius: 999px;
            background: var(--flag-bg); color: var(--flag);
            font-size: 0.7rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em;
            vertical-align: 2px;
        }
        details { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 12px 16px; }
        summary { cursor: pointer; font-weight: 600; }
        pre.notes {
            margin: 12px 0 0; white-space: pre-wrap; word-wrap: break-word;
            font: 15px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--muted);
        }
        footer { margin-top: 36px; color: var(--muted); font-size: 0.85rem; }
        footer p { margin: 0; }
        @media print {
            :root { --bg: #ffffff; --card: #ffffff; --text: #000000; --muted: #333333; --line: #bbbbbb; }
            #study, footer { display: none; }
            details:not([open]) > *:not(summary) { display: block; }
            ol.cards li { break-inside: avoid; }
        }
        """#

    static let script = #"""
        (function () {
            var payload = document.getElementById("\#(payloadElementID)");
            if (!payload) { return; }
            var deck;
            try { deck = JSON.parse(payload.textContent); } catch (error) { return; }
            var cards = (deck && deck.cards) || [];
            if (!cards.length) { return; }

            var study = document.getElementById("study");
            var face = document.getElementById("card");
            var sideLabel = document.getElementById("side-label");
            var cardText = document.getElementById("card-text");
            var hint = face.querySelector(".hint");
            var progress = document.getElementById("progress");
            var index = 0;
            var showingAnswer = false;

            function render() {
                var card = cards[index];
                sideLabel.textContent = showingAnswer ? "Answer" : "Question";
                cardText.textContent = showingAnswer ? card.back : card.front;
                hint.textContent = showingAnswer ? "Tap to see the question" : "Tap to see the answer";
                face.classList.toggle("answer", showingAnswer);
                face.classList.toggle("priority", !!card.isPriority);
                progress.textContent = (index + 1) + " of " + cards.length +
                    (card.isPriority ? " · on the exam" : "");
            }

            function move(step) {
                index = (index + step + cards.length) % cards.length;
                showingAnswer = false;
                render();
            }

            face.addEventListener("click", function () {
                showingAnswer = !showingAnswer;
                render();
            });
            document.getElementById("prev").addEventListener("click", function () { move(-1); });
            document.getElementById("next").addEventListener("click", function () { move(1); });
            document.addEventListener("keydown", function (event) {
                if (event.key === "ArrowRight") { move(1); }
                else if (event.key === "ArrowLeft") { move(-1); }
            });

            study.hidden = false;
            render();
        })();
        """#
}
