/**
 * The registration page served at armedit.oeaio.com.
 *
 * One page, no build step, no framework: it collects the two accesses an
 * account requires plus the password that seeds its pad, and shows the single
 * key the editor will carry.
 */
final class Page {

    private Page() {}

    static final String HTML = """
            <!doctype html>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width,initial-scale=1">
            <title>armedit</title>
            <style>
            :root{color-scheme:dark}
            body{background:#141618;color:#8ae2b8;font:15px/1.6 ui-monospace,Menlo,monospace;margin:0;padding:48px 20px;display:flex;justify-content:center}
            main{width:100%;max-width:640px}
            h1{font-size:34px;letter-spacing:.18em;margin:0 0 4px}
            p.sub{color:#5c7a6c;margin:0 0 36px}
            fieldset{border:1px solid #26302c;padding:20px;margin:0 0 20px}
            legend{padding:0 8px;color:#e2b85a;letter-spacing:.1em;font-size:12px}
            label{display:block;margin:14px 0 4px;color:#5c7a6c;font-size:12px;letter-spacing:.08em}
            input{width:100%;box-sizing:border-box;background:#0e1012;border:1px solid #26302c;color:#8ae2b8;font:14px ui-monospace,Menlo,monospace;padding:9px 10px}
            input:focus{outline:none;border-color:#8ae2b8}
            button{margin-top:22px;width:100%;background:#8ae2b8;color:#0e1012;border:0;padding:12px;font:600 14px ui-monospace,Menlo,monospace;letter-spacing:.1em;cursor:pointer}
            button:disabled{opacity:.5;cursor:default}
            #out{margin-top:24px;padding:16px;border:1px solid #26302c;white-space:pre-wrap;word-break:break-all;display:none}
            #out.on{display:block}
            .err{color:#e2725a}
            .key{color:#e2b85a;font-size:17px}
            small{color:#4a5a52;display:block;margin-top:10px;line-height:1.7}
            </style>
            <main>
            <h1>ARMEDIT</h1>
            <p class="sub">A text editor in assembly. Bind your accesses once; the editor carries a single key.</p>
            <form id="f">
            <fieldset>
            <legend>AICOIN WALLET</legend>
            <label for="w">API token from your aicoin wallet page</label>
            <input id="w" autocomplete="off" spellcheck="false" placeholder="eyJhZGRyIjoi...">
            <small>Pays for this account's model calls. aicoin fronts Claude and the other providers, so this one token covers all of them, and armedit never holds a provider key.</small>
            </fieldset>
            <fieldset>
            <legend>AWS ACCESS</legend>
            <label for="k">Access key id</label>
            <input id="k" autocomplete="off" spellcheck="false" placeholder="AKIA...">
            <label for="s">Secret access key</label>
            <input id="s" type="password" autocomplete="off" spellcheck="false">
            <label for="r">Region</label>
            <input id="r" autocomplete="off" spellcheck="false" value="us-east-1">
            <small>Used to bring up and tear down this account's instance. Both accesses are required: an account with only one of them cannot work.</small>
            </fieldset>
            <fieldset>
            <legend>PASSWORD</legend>
            <label for="p">Chosen by you, never stored in the clear anywhere else</label>
            <input id="p" type="password" autocomplete="new-password">
            <small>Seeds this account's pad windows, together with the exact nanosecond it was created, its id, and a random value private to the server.</small>
            </fieldset>
            <button id="b" type="submit">ISSUE KEY</button>
            </form>
            <div id="out"></div>

            <div id="more" style="display:none">
            <fieldset>
            <legend>OTHER CLOUDS</legend>
            <small>Optional, and addable any time. With more than one bound, work goes to whichever can run it most cheaply - unless it names resources that only live somewhere specific, in which case it goes there.</small>
            <label for="cp">Provider</label>
            <select id="cp" style="width:100%;box-sizing:border-box;background:#0e1012;border:1px solid #26302c;color:#8ae2b8;font:14px ui-monospace,Menlo,monospace;padding:9px 10px">
            <option value="hetzner">Hetzner Cloud - about $0.0063/hour</option>
            <option value="digitalocean">DigitalOcean - about $0.0089/hour</option>
            <option value="gcp">Google Cloud - about $0.0173/hour</option>
            <option value="azure">Microsoft Azure - about $0.0182/hour</option>
            </select>
            <label for="c1">Credential</label>
            <input id="c1" type="password" autocomplete="off" spellcheck="false" placeholder="API token, or service account JSON">
            <label for="c2">Second field, where the provider needs one</label>
            <input id="c2" autocomplete="off" spellcheck="false" placeholder="project id / subscription id">
            <button id="cb" type="button">BIND THIS CLOUD</button>
            <div id="cout"></div>
            </fieldset>
            </div>

            <small>Nothing here is stored in the armedit repository, and the key below is the only credential that ever reaches a device. No cloud credential ever appears in a prompt: the model picks a provider by name and the backend does the signing.</small>
            </main>
            <script>
            const $=i=>document.getElementById(i),out=$("out");
            let issuedKey="";
            $("f").addEventListener("submit",async e=>{
             e.preventDefault();$("b").disabled=true;out.className="on";out.textContent="registering...";
             try{
              const r=await fetch("/api/register",{method:"POST",headers:{"Content-Type":"application/json"},
               body:JSON.stringify({wallet:$("w").value.trim(),aws_key:$("k").value.trim(),
                aws_secret:$("s").value.trim(),region:$("r").value.trim(),password:$("p").value})});
              const j=await r.json();
              if(j.key){issuedKey=j.key;$("more").style.display="block";
               out.innerHTML='<span class="key">'+j.key+'</span>'+
               "\\n\\nRun the editor with:\\n  export ARMEDIT_KEY="+j.key+"\\n  make win\\n\\nThis key is shown once, and it is the only setting the editor needs.";}
              else{out.innerHTML='<span class="err">'+(j.error||"registration failed")+"</span>";}
             }catch(x){out.innerHTML='<span class="err">'+x+"</span>";}
             $("b").disabled=false;
            });

            $("cb").addEventListener("click",async()=>{
             const p=$("cp").value,cout=$("cout");
             const fields={hetzner:["api_token"],digitalocean:["api_token"],
              gcp:["service_account_json","project_id"],
              azure:["client_secret","subscription_id"]}[p];
             const body={provider:p};body[fields[0]]=$("c1").value.trim();
             if(fields[1])body[fields[1]]=$("c2").value.trim();
             cout.textContent="binding...";
             try{
              const r=await fetch("/api/clouds",{method:"POST",
               headers:{"Content-Type":"application/json","X-Armedit-Key":issuedKey},
               body:JSON.stringify(body)});
              const j=await r.json();
              cout.innerHTML=j.error?'<span class="err">'+j.error+"</span>"
               :(j.complete?p+" bound.":p+" needs every field before it can be used.");
              $("c1").value="";$("c2").value="";
             }catch(x){cout.innerHTML='<span class="err">'+x+"</span>";}
            });
            </script>
            """;
}
