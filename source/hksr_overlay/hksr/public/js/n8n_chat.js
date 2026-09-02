// ERPNext AI Assistant v2 — bootstrap through Frappe before creating the n8n widget.
(function () {
  "use strict";

  var initialized = false;

  async function loadVisibleHistory() {
    try {
      var response = await frappe.call({
        method: "hksr.ai_assistant.api.chat_history",
        type: "GET",
      });
      var messages = response && response.message && response.message.messages;
      return Array.isArray(messages) ? messages : [];
    } catch (error) {
      console.info("ERPNext AI Assistant history is temporarily unavailable.");
      return [];
    }
  }

  function hydrateVisibleHistory(chatApp, messages) {
    if (!chatApp || !Array.isArray(messages) || !messages.length) return;
    var chat = chatApp.config && chatApp.config.globalProperties
      ? chatApp.config.globalProperties.$chat
      : null;
    var messageState = chat && chat.messages;
    if (messageState && typeof messageState === "object" && "value" in messageState) {
      messageState.value = messages;
    } else if (Array.isArray(messageState)) {
      messageState.splice.apply(messageState, [0, messageState.length].concat(messages));
    }
  }

  async function initChat() {
    if (initialized) return;
    if (!window.frappe || !frappe.session || frappe.session.user === "Guest") return;
    if (!window.N8nChat || typeof N8nChat.createChat !== "function") return;

    try {
      var response = await frappe.call({
        method: "hksr.ai_assistant.api.bootstrap",
        type: "GET",
      });
      var config = response && response.message;
      if (!config || !config.enabled) return;

      var visibleHistory = await loadVisibleHistory();

      initialized = true;
      var chatApp = N8nChat.createChat({
        webhookUrl: window.location.origin + config.webhook_url,
        webhookConfig: {
          method: "POST",
        },
        mode: "window",
        showWelcomeScreen: false,
        defaultOpen: false,
        loadPreviousSession: false,
        sessionId: config.session_id,
        metadata: {
          aiSessionToken: config.token,
          aiSessionId: config.session_id,
          siteId: config.site_id,
        },
        initialMessages: ["Hi! I am the ERPNext AI Assistant. Ask me about data you are permitted to read."],
        i18n: {
          en: {
            title: "ERPNext AI Assistant",
            subtitle: "Permission-aware answers powered by Gemini",
            inputPlaceholder: "Ask a question...",
            getStarted: "Start Chat",
            footer: "",
          },
        },
      });
      hydrateVisibleHistory(chatApp, visibleHistory);
    } catch (error) {
      // Disabled/unconfigured is intentionally silent; never fall back to the insecure webhook.
      console.info("ERPNext AI Assistant v2 is unavailable.");
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initChat, { once: true });
  } else {
    initChat();
  }
})();
