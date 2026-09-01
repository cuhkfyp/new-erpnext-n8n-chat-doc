frappe.ui.form.on("AI Assistant Settings", {
  refresh(frm) {
    if (frm.is_new() || !frappe.user.has_role("System Manager")) return;

    frm.add_custom_button(__("Sync Now"), async () => {
      await frappe.call({
        method: "hksr.ai_assistant.api.request_schema_sync",
        freeze: true,
        freeze_message: __("Queueing schema synchronization..."),
      });
      frappe.show_alert({ message: __("Schema synchronization queued."), indicator: "green" });
      await frm.reload_doc();
    });
  },
});
