defmodule BeamCom.Protocol.Instance do
  @moduledoc """
  The Accord contract for the life of one instance (a Durable Object of
  `priv/wasm_host/worker/durable.js`, with `BEAM_INSTANCES`).

  ## States

  * `:fresh` — the object has no time limit. A request gets 410.
  * `:running` — the registry started the instance with its time limit.
    A request goes to the VM.
  * `:expired` — the storage of the object is deleted, and its VM
    stopped. A request gets 410, and no other reply. This state accepts
    no start.

  ## Events

  * `:start` — the registry gives the time limit (`start/1`).
  * `:fetch` — a request. The reply is `:served` or `:gone` (410).
  * `:alarm` — the alarm of the object at its time limit (`alarm/0`). It
    deletes the storage.
  * `:expire` — the sweep of the registry, or a request after the limit,
    deletes the storage (`expire/0`).

  ## Properties that TLC checks

  * `each_instance_ends`: a running instance always reaches `:expired`,
    when the alarm always fires in the end (weak fairness of `:alarm`).
  * `expired_has_no_storage`: in `:expired`, the storage is deleted.
  * `expired_is_reachable`.

  The registry and its limits have their own model: `specs/Admission.tla`.
  """
  use Accord.Protocol

  role(:host)
  role(:contract)

  initial(:fresh)

  track(:deleted, :boolean, default: false)

  state :fresh do
    on(:fetch, reply: :gone, goto: :fresh)

    cast :start do
      goto(:running)
    end
  end

  state :running do
    on(:fetch, reply: :served, goto: :running)

    # The alarm of the object, at its time limit (BEAM_INSTANCE_TTL).
    cast :alarm do
      goto(:expired)
      update(fn _msg, tracks -> %{tracks | deleted: true} end)
    end

    cast :expire do
      goto(:expired)
      update(fn _msg, tracks -> %{tracks | deleted: true} end)
    end
  end

  state :expired do
    # After the end, a request gets 410: the contract has no other reply.
    on(:fetch, reply: :gone, goto: :expired)

    # An alarm or a sweep after the end deletes nothing more.
    cast :alarm do
      goto(:expired)
    end

    cast :expire do
      goto(:expired)
    end
  end

  # The runtime always runs an alarm at its time: weak fairness of :alarm.
  property :each_instance_ends do
    liveness(in_state(:running), leads_to: in_state(:expired), assuming: [:alarm])
  end

  property :expired_has_no_storage do
    invariant(:expired, fn _msg, tracks -> tracks.deleted end)
  end

  property :expired_is_reachable do
    reachable(:expired)
  end
end
