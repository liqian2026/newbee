defmodule Newbee.CommandsTest do
   test "空输入 :ok" do
     assert :ok = Commands.handle("   ", %{say: fn _ -> :ok end})
   end
+
+  test "/resume 无参数返回 {:resume_picker, metas} 且含最新会话" do
+    s = Newbee.Session.open("test_resume_#{:erlang.unique_integer([:positive])}")
+    Newbee.Session.append(s, %{"role" => "user", "content" => "帮我做个功能"})
+
+    assert {:resume_picker, metas} = Commands.handle("/resume", %{say: fn _ -> :ok end})
+    assert Enum.any?(metas, &(&1.id == s.id))
+  end
+
+  test "/resume 精确 id 与前缀都返回 {:resume, id}" do
+    s = Newbee.Session.open("test_resume_#{:erlang.unique_integer([:positive])}")
+    Newbee.Session.append(s, %{"role" => "user", "content" => "hi"})
+    pref = String.slice(s.id, 0, String.length(s.id) - 1)
+
+    assert {:resume, resumed} = Commands.handle("/resume #{s.id}", %{say: fn _ -> :ok end})
+    assert resumed == s.id
+    assert {:resume, resumed2} = Commands.handle("/resume #{pref}", %{say: fn _ -> :ok end})
+    assert resumed2 == s.id
+  en
… [compressed: 9481 bytes, 235 lines; 用 binding 变量或写文件后再局部读取] …
t.first(messages)["role"] == "system"
+          {:ok, %{"role" => "assistant", "content" => "one", "tool_calls" => []}, %{}}
+        end
+      )
+
+    assert {:text, "one"} = Kernel.submit(first, "first")
+    first_prompt = :sys.get_state(first).messages |> List.first() |> Map.fetch!("content")
+    GenServer.stop(first)
+
+    {:ok, resumed} =
+      Kernel.start_link(
+        client: %{},
+        evaluator: ev,
+        session_id: sid,
+        client_fun: fn messages, _on_text ->
+          assert List.first(messages)["content"] == first_prompt
+          {:ok, %{"role" => "assistant", "content" => "two", "tool_calls" => []}, %{}}
+        end
+      )
+
+    assert {:text, "two"} = Kernel.submit(resumed, "second")
+  end
+
   test "Esc 中断：client 返回 {:interrupted, content} 时 turn 立即终止" do
     {:ok, ev} = Evaluator.start(mode: :local)
 
diff --git a/test/newbee/evolution/metrics_test.exs b/test/newbee/evolution/metrics_test.exs
index d4b5249..9085cd8 100644
--- a/test/newbee/evolution/metrics_test.exs
+++ b/test/newbee/evolution/metrics_test.exs
@@ -6,6 +6,7 @@ 