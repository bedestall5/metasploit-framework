shared_examples_for 'Rex::Encoder::Alpha2::Generic' do

  describe ".encode_byte" do
    subject { described_class.encode_byte(block, badchars) }

    context "when too many badchars" do
      let(:block) { 0x41 }
      let(:badchars) { (0x00..0xff).to_a.pack("C*") }

      it "raises an error" do
        expect { subject }.to raise_error(RuntimeError)
      end
    end

    context "when encoding is possible" do
      let(:block) { 0x41 }
      let(:badchars) { 'B' }

      it "returns two-bytes encoding" do
        expect(subject.length).to eq(2)
      end

      it "returns encoding without badchars" do
        badchars.each_char do |b|
          is_expected.to_not include(badchars)
        end
      end
    end

  end

  describe ".encode" do
    subject { described_class.encode(buf, reg, offset, badchars) }
    let(:buf) { 'ABCD' }
    let(:reg) { 'ECX' }
    let(:offset) { 0 }

    context "when too many badchars" do
      let(:badchars) { (0x00..0xff).to_a.pack("C*") }

      it "raises an error" do
        expect { subject }.to raise_error(RuntimeError)
      end
    end

    context "when encoding is possible" do
      let(:badchars) { 'B' }

      it "returns encoding without badchars" do
        badchars.each_char do |b|
          is_expected.to_not include(b)
        end
      end

      it "returns encoding ending with terminator" do
        is_expected.to end_with(described_class.add_terminator)
      end
    end
  end

  describe ".add_terminator" do
    subject { described_class.add_terminator }

    it { is_expected.to eq('AA') }
  end

end
