# frozen_string_literal: true

class MessagesController < ActionController::Base
  def index
    @messages = Message.order(:id)
  end
end
