#!/usr/bin/env ruby

$:.unshift "#{File.dirname(__FILE__)}/lib"

require 'rubygems'
require 'mechanize'
require 'builder'

# My bits and bobs
require 'id'
require 'speech'
require 'configuration'
require 'people'

conf = Configuration.new

# First load people back in so that we can look up member id's
people = People.read_xml('pwdata/members/people.xml', 'pwdata/members/all-members.xml')

system("mkdir -p pwdata/scrapedxml/debates")

# House Hansard for 20 September 2007
url = "http://parlinfoweb.aph.gov.au/piweb/browse.aspx?path=Chamber%20%3E%20House%20Hansard%20%3E%202007%20%3E%2020%20September%202007"
date = Date.new(2007, 9, 20)

# Required to workaround long viewstates generated by .NET (whatever that means)
# See http://code.whytheluckystiff.net/hpricot/ticket/13
Hpricot.buffer_size = 262144

agent = WWW::Mechanize.new
agent.set_proxy(conf.proxy_host, conf.proxy_port)
page = agent.get(url)

xml_filename = "pwdata/scrapedxml/debates/debates#{date}.xml"
xml = File.open(xml_filename, 'w')
x = Builder::XmlMarkup.new(:target => xml, :indent => 1)

title = ""
subtitle = ""

def quote(text)
  text.sub('&', '&amp;')
end

id = Id.new("uk.org.publicwhip/debate/#{date}.")

x.instruct!

# Merges together two or more speeches by the same person that occur consecutively
class SpeechOutputter
  def initialize(x)
    @old_speech = Speech.new
    @x = x
  end
  
  def speech(speakername, time, url, id, speakerid, content)
    if speakername != @old_speech.speakername
      if @old_speech.speakername
        @old_speech.output(@x)
      end
      @old_speech = Speech.new(speakername, time, url, id, speakerid)
    end
    @old_speech.append_to_content(content)
  end
  
  def finish
    @old_speech.output(@x)
  end
end

# Returns id of speakername
def lookup_speakername(speakername, people, date)
  # HACK alert (Oh you know what this whole thing is a big hack alert)
  if speakername.downcase == "the speaker"
    speakername = "Mr David Hawker"
  elsif speakername.downcase == "the deputy speaker"
    speakername = "Mr Ian Causley"
  end

  # Lookup id of member based on speakername
  if speakername.downcase == "unknown"
    nil
  else
    puts "Looking up name: #{Name.title_first_last(speakername).full_name}"
    people.find_member_by_name(Name.title_first_last(speakername), date).id
  end
end

def speech(speakername, content, x, people, time, url, id, speech_outputter, date)
  # I'm completely guessing here the meaning of p.paraitalic
  if content[0] && content[0].attributes["class"] == "paraitalic"
    puts "Overriding speaker name"
    p content[0].attributes["class"]
    # Override speaker name
    speakername = "unknown"
  end
  speakerid = lookup_speakername(speakername, people, date)
  speech_outputter.speech(speakername, time, url, id, speakerid, content)
end

x.publicwhip do
  # Structure of the page is such that we are only interested in some of the links
  for link in page.links[30..-4] do
  #for link in page.links[108..108] do
    #puts "Processing: #{link}"
  	# Only going to consider speeches for the time being
  	if link.to_s =~ /Speech:/
    	# Link text for speech has format:
    	# HEADING > NAME > HOUR:MINS:SECS
    	split = link.to_s.split('>').map{|a| a.strip}
    	puts "Warning: Expected split to have length 3" unless split.size == 3
    	time = split[2]
     	sub_page = agent.click(link)
     	# Extract permanent URL of this subpage. Also, quoting because there is a bug
     	# in XML Builder that for some reason is not quoting attributes properly
     	url = quote(sub_page.links.text("[Permalink]").uri.to_s)
    	# Type of page. Possible values: No, Speech, Bills
    	type = sub_page.search('//span[@id=dlMetadata__ctl7_Label3]/*').to_s
    	puts "Warning: Expected type Speech but was type #{type}" unless type == "Speech"
   	  newtitle = sub_page.search('div#contentstart div.hansardtitle').inner_html
   	  newsubtitle = sub_page.search('div#contentstart div.hansardsubtitle').inner_html

   	  # Only add headings if they have changed
   	  if newtitle != title
     	  x.tag!("major-heading", newtitle, :id => id, :url => url)
      end
   	  if newtitle != title || newsubtitle != subtitle
     	  x.tag!("minor-heading", newsubtitle, :id => id, :url => url)
      end
      title = newtitle
      subtitle = newsubtitle
      
      speech_outputter = SpeechOutputter.new(x)
      
      # Untangle speeches from subspeeches
      speech_content = Hpricot::Elements.new
    	content = sub_page.search('div#contentstart > div.speech0 > *')
    	main_speakername = ""
    	content.each do |e|
    	  if e.attributes["class"] == "subspeech0" || e.attributes["class"] == "subspeech1"
          # Extract speaker name from link
          if main_speakername == ""
            main_speakername = speech_content.search('span.talkername a').first.inner_html
          end
    	    speech(main_speakername, speech_content, x, people, time, url, id, speech_outputter, date)
          # Extract speaker name from link
          if e.search('span.talkername a').first.nil?
              speakername = "unknown"
          else
            speakername = e.search('span.talkername a').first.inner_html
          end
    	    speech(speakername, e, x, people, time, url, id, speech_outputter, date)
    	    speech_content.clear
    	  else
    	    speech_content << e
  	    end
    	end
      # Extract speaker name from link
      if main_speakername == ""
        main_speakername = speech_content.search('span.talkername a').first.inner_html
      end
	    speech(main_speakername, speech_content, x, people, time, url, id, speech_outputter, date)
	    speech_outputter.finish    
    end
  end
end

xml.close

# Temporary hack: nicely indent XML
system("tidy -quiet -indent -xml -modify -wrap 0 -utf8 #{xml_filename}")

# And load up the database
system(conf.web_root + "/twfy/scripts/xml2db.pl --debates --all --force")