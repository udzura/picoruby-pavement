class CancellationApp < Pavement::Base
  tool "work" do
    enable :cancellation, :progress
    input { string :mode, default: "checkpoint" }
    call do |mode:|
      progress(0, total: 1) if mode == "progress"
      Cloudflare.fetch("https://cancellation.test/start")
      if mode == "poll" && cancelled?
        "cancelled"
      else
        mode == "progress" ? progress(1, total: 1) : check_cancelled!
        Cloudflare.fetch("https://cancellation.test/after")
        "done"
      end
    ensure
      Cloudflare.fetch("https://cancellation.test/cleanup")
    end
  end
end

Rackup::Handler::CloudflareWorker.run(CancellationApp)
