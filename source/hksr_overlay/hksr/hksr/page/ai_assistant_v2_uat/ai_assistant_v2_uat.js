// Isolated same-origin acceptance launcher for ERPNext AI Assistant v2.
(function () {
	"use strict";

	var PAGE_NAME = "ai-assistant-v2-uat";
	var TARGET_ID = "ai-assistant-v2-uat-chat";

	function set_status(state, message, kind) {
		state.status
			.removeClass("alert-info alert-success alert-danger")
			.addClass("alert-" + kind)
			.text(message);
	}

	function hide_legacy_widget() {
		document.body.classList.add("ai-assistant-v2-uat-open");
	}

	function show_legacy_widget() {
		document.body.classList.remove("ai-assistant-v2-uat-open");
	}

	function stop_tail_follow(state) {
		if (state.chat_observer) {
			state.chat_observer.disconnect();
		}
		if (state.chat_scroll_frame) {
			window.cancelAnimationFrame(state.chat_scroll_frame);
		}
		if (state.chat_scroll_body && state.chat_scroll_listener) {
			state.chat_scroll_body.removeEventListener("scroll", state.chat_scroll_listener);
		}
		state.chat_observer = null;
		state.chat_scroll_frame = null;
		state.chat_scroll_body = null;
		state.chat_scroll_listener = null;
		state.follow_chat_tail = true;
		state.force_chat_tail_pending = false;
	}

	function schedule_tail_follow(state, force) {
		if (force) {
			state.follow_chat_tail = true;
			state.force_chat_tail_pending = true;
		}
		if (state.chat_scroll_frame) {
			window.cancelAnimationFrame(state.chat_scroll_frame);
		}

		state.chat_scroll_frame = window.requestAnimationFrame(function () {
			state.chat_scroll_frame = window.requestAnimationFrame(function () {
				state.chat_scroll_frame = null;
				var body = state.target[0] && state.target[0].querySelector(".chat-body");
				if (!body) return;

				if (state.chat_scroll_body !== body) {
					if (state.chat_scroll_body && state.chat_scroll_listener) {
						state.chat_scroll_body.removeEventListener("scroll", state.chat_scroll_listener);
					}
					state.chat_scroll_body = body;
					state.chat_scroll_listener = function () {
						var distance = body.scrollHeight - body.scrollTop - body.clientHeight;
						state.follow_chat_tail = distance <= 48;
					};
					body.addEventListener("scroll", state.chat_scroll_listener, { passive: true });
				}

				if (state.force_chat_tail_pending || state.follow_chat_tail) {
					body.scrollTop = body.scrollHeight;
					state.follow_chat_tail = true;
					state.force_chat_tail_pending = false;
				}
			});
		});
	}

	function start_tail_follow(state) {
		stop_tail_follow(state);
		state.follow_chat_tail = true;
		state.chat_observer = new MutationObserver(function (records) {
			var message_added = false;
			var message_content_changed = false;
			for (var index = 0; index < records.length; index += 1) {
				var record = records[index];
				var target =
					record.target.nodeType === 1 ? record.target : record.target.parentElement;
				if (target && target.closest(".chat-message")) {
					message_content_changed = true;
				}

				var added = record.addedNodes;
				for (var node_index = 0; node_index < added.length; node_index += 1) {
					var node = added[node_index];
					if (
						node.nodeType === 1 &&
						(node.matches(".chat-message") || node.querySelector(".chat-message"))
					) {
						message_added = true;
					}
				}
			}
			var keep_following_changed_message =
				message_content_changed &&
				(state.follow_chat_tail || state.force_chat_tail_pending);
			schedule_tail_follow(state, message_added || keep_following_changed_message);
		});
		state.chat_observer.observe(state.target[0], {
			childList: true,
			subtree: true,
			characterData: true,
		});
		schedule_tail_follow(state, true);
	}

	function stop_chat(state) {
		stop_tail_follow(state);
		if (state.chat_app && typeof state.chat_app.unmount === "function") {
			state.chat_app.unmount();
		}
		state.chat_app = null;
		state.target.empty();
	}

	async function start_chat(wrapper, force) {
		var state = wrapper.ai_assistant_v2_uat;
		if (!state || state.starting || (state.chat_app && !force)) return;

		state.starting = true;
		hide_legacy_widget();
		if (force) stop_chat(state);
		set_status(state, __("Connecting through your current ERPNext session…"), "info");

		try {
			if (!window.N8nChat || typeof window.N8nChat.createChat !== "function") {
				throw new Error("The n8n chat client is not loaded.");
			}

			var response = await frappe.call({
				method: "hksr.ai_assistant.api.bootstrap",
				type: "GET",
			});
			var config = response && response.message;
			if (!config || !config.enabled || !config.webhook_url || !config.token || !config.session_id) {
				throw new Error("Frappe did not return a complete v2 bootstrap response.");
			}

			state.target.empty();
			state.chat_app = window.N8nChat.createChat({
				target: "#" + TARGET_ID,
				webhookUrl: window.location.origin + config.webhook_url,
				webhookConfig: {
					method: "POST",
				},
				mode: "fullscreen",
				showWelcomeScreen: false,
				loadPreviousSession: false,
				sessionId: config.session_id,
				metadata: {
					aiSessionToken: config.token,
					aiSessionId: config.session_id,
					siteId: config.site_id,
					uatCanary: true,
				},
				initialMessages: [
					"AI Assistant v2 acceptance session. Ask a greeting or a question about data you are permitted to read.",
				],
				i18n: {
					en: {
						title: "ERPNext AI Assistant v2 — Acceptance",
						subtitle: "Permission-aware canary; current ERPNext session",
						inputPlaceholder: "Ask a test question…",
						getStarted: "Start acceptance chat",
						footer: "UAT canary — no raw SQL",
					},
				},
			});
			start_tail_follow(state);

			var minutes = Math.max(1, Math.floor(Number(config.expires_in || 0) / 60));
			set_status(
				state,
				__("Connected securely. The opaque browser token expires in approximately {0} minutes.", [minutes]),
				"success"
			);
		} catch (error) {
			stop_chat(state);
			set_status(
				state,
				__("The v2 acceptance assistant is unavailable: {0}", [error && error.message ? error.message : error]),
				"danger"
			);
		} finally {
			state.starting = false;
		}
	}

	frappe.pages[PAGE_NAME].on_page_load = function (wrapper) {
		var page = frappe.ui.make_app_page({
			parent: wrapper,
			title: __("AI Assistant v2 Acceptance"),
			single_column: true,
		});

		var body = $(
			'<div class="ai-assistant-v2-uat">' +
				'<div class="alert alert-info ai-assistant-v2-uat-status" role="status"></div>' +
				'<div class="ai-assistant-v2-uat-help">' +
					'<strong>Acceptance-only launcher.</strong> This page uses your real ERPNext login and permission checks. ' +
					'Uncredentialed or forged n8n requests are rejected; use this Page for valid tests. ' +
					'Close this page when your test is complete.' +
				'</div>' +
				'<div id="' + TARGET_ID + '" class="ai-assistant-v2-uat-chat"></div>' +
			'</div>'
		).appendTo(page.body);

		wrapper.ai_assistant_v2_uat = {
			chat_app: null,
			chat_observer: null,
			chat_scroll_body: null,
			chat_scroll_frame: null,
			chat_scroll_listener: null,
			follow_chat_tail: true,
			force_chat_tail_pending: false,
			starting: false,
			status: body.find(".ai-assistant-v2-uat-status"),
			target: body.find("#" + TARGET_ID),
		};

		page.set_primary_action(__("Reconnect"), function () {
			start_chat(wrapper, true);
		}, "refresh");

		$(wrapper).on("hide.ai-assistant-v2-uat", function () {
			show_legacy_widget();
			stop_chat(wrapper.ai_assistant_v2_uat);
		});
	};

	frappe.pages[PAGE_NAME].on_page_show = function (wrapper) {
		start_chat(wrapper, false);
	};
})();
